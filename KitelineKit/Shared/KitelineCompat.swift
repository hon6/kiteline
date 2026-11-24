import SwiftUI

// MARK: - 为什么有这个文件
//
// Mac 版支持到 macOS 12。下面这些是 macOS 13 / 14 才有的 SwiftUI 写法的兼容版：
// 新系统（macOS 13/14+、iPhone、手表）上直接调原来的接口，外观、行为完全不变；只有 macOS 12 / 13 上走近似的实现。
// 代码里统一写兼容版的名字（klSnappy、klOnGeometryChange、KLLabeledContent……），别直接写原接口，
// 不然 Mac 版编不过（Mac 编译目标是 macOS 12，见 build.sh 的 MINOS）。观察数据的那套在 KitelineObservation.swift。

// MARK: 动画

extension Animation {
    /// 代替 .snappy（macOS 14）：旧系统上用差不多手感的弹簧
    public static var klSnappy: Animation { klSnappy() }

    public static func klSnappy(duration: TimeInterval = 0.5, extraBounce: Double = 0) -> Animation {
        if #available(macOS 14, iOS 17, watchOS 10, tvOS 17, *) { return .snappy(duration: duration, extraBounce: extraBounce) }
        return .spring(response: duration, dampingFraction: max(0.1, 1 - (0.15 + extraBounce)))
    }

    /// 代替 .smooth（macOS 14）
    public static var klSmooth: Animation { klSmooth() }

    public static func klSmooth(duration: TimeInterval = 0.5, extraBounce: Double = 0) -> Animation {
        if #available(macOS 14, iOS 17, watchOS 10, tvOS 17, *) { return .smooth(duration: duration, extraBounce: extraBounce) }
        return .spring(response: duration, dampingFraction: max(0.1, 1 - extraBounce))
    }
}

// MARK: 尺寸变化

extension View {
    #if !os(iOS) && !KL_MODERN
    /// 代替 onGeometryChange(for:of:action:)（macOS 13）
    public func klOnGeometryChange<T: Equatable>(for type: T.Type, of transform: @escaping (GeometryProxy) -> T,
                                                 action: @escaping (T) -> Void) -> some View {
        modifier(KLGeometryChange(transform: transform, single: action, pair: nil))
    }
    #endif

    #if !os(iOS) && !KL_MODERN
    /// 代替 onGeometryChange(for:of:action:)（两个参数：旧值、新值；这个系统接口 macOS 15 才有）
    public func klOnGeometryChange<T: Equatable>(for type: T.Type, of transform: @escaping (GeometryProxy) -> T,
                                                 action: @escaping (T, T) -> Void) -> some View {
        modifier(KLGeometryChange(transform: transform, single: nil, pair: action))
    }
    #endif
}

#if !os(iOS) && !KL_MODERN
private struct KLGeometryChange<T: Equatable>: ViewModifier {
    let transform: (GeometryProxy) -> T
    let single: ((T) -> Void)?
    let pair: ((T, T) -> Void)?

    func body(content: Content) -> some View {
        #if os(macOS) && !KL_MODERN
        if let single, #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) {
            content.onGeometryChange(for: T.self, of: transform, action: single)
        } else if let pair, #available(macOS 15, iOS 18, watchOS 11, tvOS 18, *) {
            content.onGeometryChange(for: T.self, of: transform, action: pair)
        } else {
            content.background(GeometryReader { proxy in
                let value = transform(proxy)
                Color.clear
                    .onAppear { fire(value, value) }
                    .onChange(of: value) { [value] newValue in fire(value, newValue) }
            })
        }
        #elseif os(iOS) || KL_MODERN
        if let single {
            content.onGeometryChange(for: T.self, of: transform, action: single)
        } else if let pair {
            content.onGeometryChange(for: T.self, of: transform, action: pair)
        }
        #else
        if let single, #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) {
            content.onGeometryChange(for: T.self, of: transform, action: single)
        } else if let pair, #available(macOS 15, iOS 18, watchOS 11, tvOS 18, *) {
            content.onGeometryChange(for: T.self, of: transform, action: pair)
        } else {
            content.background(GeometryReader { proxy in
                let value = transform(proxy)
                Color.clear
                    .onAppear { fire(value, value) }
                    .onChange(of: value) { [value] newValue in fire(value, newValue) }
            })
        }
        #endif
    }

    private func fire(_ old: T, _ new: T) {
        if let pair { pair(old, new) } else { single?(new) }
    }
}
#endif

// MARK: 菜单样式

extension View {
    #if !os(iOS) && !KL_MODERN
    /// 代替 .menuStyle(.button)（macOS 13）：旧系统上用无边框按钮样式，外面再套的 .buttonStyle 照样生效
    @ViewBuilder
    public func klMenuButtonStyle() -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13, *) { menuStyle(.button) } else { menuStyle(.borderlessButton) }
        #elseif os(iOS) || KL_MODERN
        menuStyle(.button)
        #else
        self
        #endif
    }
    #endif
}

// MARK: LabeledContent（macOS 13）

#if os(iOS) || KL_MODERN
// iPhone / iPad（iOS 18 起）和 Mac 主包（macOS 14 起）直接用系统类型：编出来和不用兼容版完全一样
public typealias KLLabeledContent<Label: View, Content: View> = LabeledContent<Label, Content>
#else
/// 代替 LabeledContent：新系统上就是 LabeledContent（表单里的样式不变），macOS 12 上是左标题、右内容的一行
public struct KLLabeledContent<Label: View, Content: View>: View {
    private enum Kind {
        case views
        case keyValue(LocalizedStringKey, String)
        case textValue(String, String)
        case keyContent(LocalizedStringKey)
        case textContent(String)
    }
    private let kind: Kind
    private let content: () -> Content
    private let label: () -> Label

    public init(@ViewBuilder content: @escaping () -> Content, @ViewBuilder label: @escaping () -> Label) {
        kind = .views; self.content = content; self.label = label
    }

    public var body: some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13, *) {
            switch kind {
            case .views: LabeledContent(content: content, label: label)
            case .keyValue(let key, let value): LabeledContent(key, value: value)
            case .textValue(let title, let value): LabeledContent(title, value: value)
            case .keyContent(let key): LabeledContent(key, content: content)
            case .textContent(let title): LabeledContent(title, content: content)
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                switch kind {
                case .views: label()
                case .keyValue(let key, _), .keyContent(let key): Text(key)
                case .textValue(let title, _), .textContent(let title): Text(title)
                }
                Spacer(minLength: 12)
                Group {
                    switch kind {
                    case .keyValue(_, let value), .textValue(_, let value): Text(value)
                    default: content()
                    }
                }
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
            }
        }
        #elseif os(iOS) || KL_MODERN
        switch kind {
        case .views: LabeledContent(content: content, label: label)
        case .keyValue(let key, let value): LabeledContent(key, value: value)
        case .textValue(let title, let value): LabeledContent(title, value: value)
        case .keyContent(let key): LabeledContent(key, content: content)
        case .textContent(let title): LabeledContent(title, content: content)
        }
        
        #else
        if #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) {
            switch kind {
            case .views: LabeledContent(content: content, label: label)
            case .keyValue(let key, let value): LabeledContent(key, value: value)
            case .textValue(let title, let value): LabeledContent(title, value: value)
            case .keyContent(let key): LabeledContent(key, content: content)
            case .textContent(let title): LabeledContent(title, content: content)
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                switch kind {
                case .views: label()
                case .keyValue(let key, _), .keyContent(let key): Text(key)
                case .textValue(let title, _), .textContent(let title): Text(title)
                }
                Spacer(minLength: 12)
                Group {
                    switch kind {
                    case .keyValue(_, let value), .textValue(_, let value): Text(value)
                    default: content()
                    }
                }
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
            }
        }
        #endif
    }
}

extension KLLabeledContent where Label == Text {
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        kind = .keyContent(titleKey); self.content = content; label = { Text(titleKey) }
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, @ViewBuilder content: @escaping () -> Content) {
        let title = String(title)
        kind = .textContent(title); self.content = content; label = { Text(title) }
    }
}

extension KLLabeledContent where Label == Text, Content == Text {
    public init<V: StringProtocol>(_ titleKey: LocalizedStringKey, value: V) {
        let value = String(value)
        kind = .keyValue(titleKey, value); content = { Text(value) }; label = { Text(titleKey) }
    }

    @_disfavoredOverload
    public init<S: StringProtocol, V: StringProtocol>(_ title: S, value: V) {
        let title = String(title), value = String(value)
        kind = .textValue(title, value); content = { Text(value) }; label = { Text(title) }
    }
}
#endif

// MARK: ContentUnavailableView（macOS 14）

#if os(iOS) || KL_MODERN
// iPhone / iPad（iOS 18 起）和 Mac 主包（macOS 14 起）直接用系统类型：编出来和不用兼容版完全一样
public typealias KLUnavailableView<Label: View, Description: View, Actions: View> = ContentUnavailableView<Label, Description, Actions>
#else
/// 代替 ContentUnavailableView：新系统上就是它，旧系统上是居中的图标 + 标题 + 说明 + 按钮
public struct KLUnavailableView: View {
    private enum Kind {
        case views(AnyView, AnyView, AnyView)
        case key(LocalizedStringKey, String?, Text?)
        case text(String, String?, Text?)
        case search(String?)
    }
    private let kind: Kind

    public init<L: View, D: View, A: View>(@ViewBuilder label: () -> L, @ViewBuilder description: () -> D,
                                           @ViewBuilder actions: () -> A) {
        kind = .views(AnyView(label()), AnyView(description()), AnyView(actions()))
    }

    public init<L: View, D: View>(@ViewBuilder label: () -> L, @ViewBuilder description: () -> D) {
        kind = .views(AnyView(label()), AnyView(description()), AnyView(EmptyView()))
    }

    public init<L: View, A: View>(@ViewBuilder label: () -> L, @ViewBuilder actions: () -> A) {
        kind = .views(AnyView(label()), AnyView(EmptyView()), AnyView(actions()))
    }

    public init<L: View>(@ViewBuilder label: () -> L) {
        kind = .views(AnyView(label()), AnyView(EmptyView()), AnyView(EmptyView()))
    }

    public init(_ titleKey: LocalizedStringKey, systemImage: String, description: Text? = nil) {
        kind = .key(titleKey, systemImage, description)
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, systemImage: String, description: Text? = nil) {
        kind = .text(String(title), systemImage, description)
    }

    private init(kind: Kind) { self.kind = kind }

    public static var search: KLUnavailableView { KLUnavailableView(kind: .search(nil)) }
    public static func search(text: String) -> KLUnavailableView { KLUnavailableView(kind: .search(text)) }

    public var body: some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 14, *) {
            switch kind {
            case .views(let label, let description, let actions):
                ContentUnavailableView { label } description: { description } actions: { actions }
            case .key(let key, let image, let description):
                ContentUnavailableView(key, systemImage: image ?? "", description: description)
            case .text(let title, let image, let description):
                ContentUnavailableView(title, systemImage: image ?? "", description: description)
            case .search(let text):
                if let text { ContentUnavailableView.search(text: text) } else { ContentUnavailableView.search }
            }
        } else {
            VStack(spacing: 10) {
                switch kind {
                case .views(let label, let description, let actions):
                    label.font(.title2.weight(.semibold)).imageScale(.large)
                    description.font(.callout).foregroundStyle(.secondary)
                    actions
                case .key(let key, let image, let description):
                    if let image { Image(systemName: image).font(.system(size: 36)).foregroundStyle(.secondary) }
                    Text(key).font(.title2.weight(.semibold))
                    if let description { description.font(.callout).foregroundStyle(.secondary) }
                case .text(let title, let image, let description):
                    if let image { Image(systemName: image).font(.system(size: 36)).foregroundStyle(.secondary) }
                    Text(title).font(.title2.weight(.semibold))
                    if let description { description.font(.callout).foregroundStyle(.secondary) }
                case .search(let text):
                    Image(systemName: "magnifyingglass").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text(text.map { L("没有「%@」的结果", $0) } ?? L("没有结果")).font(.title2.weight(.semibold))
                }
            }
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #elseif os(iOS) || KL_MODERN
        switch kind {
        case .views(let label, let description, let actions):
            ContentUnavailableView { label } description: { description } actions: { actions }
        case .key(let key, let image, let description):
            ContentUnavailableView(key, systemImage: image ?? "", description: description)
        case .text(let title, let image, let description):
            ContentUnavailableView(title, systemImage: image ?? "", description: description)
        case .search(let text):
            if let text { ContentUnavailableView.search(text: text) } else { ContentUnavailableView.search }
        }
        
        #else
        if #available(macOS 14, iOS 17, watchOS 10, tvOS 17, *) {
            switch kind {
            case .views(let label, let description, let actions):
                ContentUnavailableView { label } description: { description } actions: { actions }
            case .key(let key, let image, let description):
                ContentUnavailableView(key, systemImage: image ?? "", description: description)
            case .text(let title, let image, let description):
                ContentUnavailableView(title, systemImage: image ?? "", description: description)
            case .search(let text):
                if let text { ContentUnavailableView.search(text: text) } else { ContentUnavailableView.search }
            }
        } else {
            VStack(spacing: 10) {
                switch kind {
                case .views(let label, let description, let actions):
                    label.font(.title2.weight(.semibold)).imageScale(.large)
                    description.font(.callout).foregroundStyle(.secondary)
                    actions
                case .key(let key, let image, let description):
                    if let image { Image(systemName: image).font(.system(size: 36)).foregroundStyle(.secondary) }
                    Text(key).font(.title2.weight(.semibold))
                    if let description { description.font(.callout).foregroundStyle(.secondary) }
                case .text(let title, let image, let description):
                    if let image { Image(systemName: image).font(.system(size: 36)).foregroundStyle(.secondary) }
                    Text(title).font(.title2.weight(.semibold))
                    if let description { description.font(.callout).foregroundStyle(.secondary) }
                case .search(let text):
                    Image(systemName: "magnifyingglass").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text(text.map { L("没有「%@」的结果", $0) } ?? L("没有结果")).font(.title2.weight(.semibold))
                }
            }
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #endif
    }
}
#endif

// MARK: 照片选择（PhotosPicker：macOS 13）

#if canImport(PhotosUI) && !os(watchOS)
import PhotosUI

#if os(iOS) || KL_MODERN
/// 主包、iPhone：就是系统的 PhotosPickerItem
public typealias KLPhotoItem = PhotosPickerItem
#else
/// 代替 PhotosPickerItem：新系统上包着它；macOS 12 上没有「照片」选择器，改从「打开」面板选的图片文件
public struct KLPhotoItem: Hashable {
    private enum Source: Hashable { case picker(AnyHashable), file(URL) }
    private let source: Source

    @available(macOS 13, iOS 16, *)
    init(picker: PhotosPickerItem) { source = .picker(AnyHashable(picker)) }
    init(file: URL) { source = .file(file) }

    @available(macOS 13, iOS 16, *)
    var pickerItem: PhotosPickerItem? { if case .picker(let item) = source { return item.base as? PhotosPickerItem }; return nil }

    /// 和 PhotosPickerItem.supportedContentTypes 一样（取扩展名用）
    public var supportedContentTypes: [UTType] {
        switch source {
        case .file(let url): return UTType(filenameExtension: url.pathExtension).map { [$0] } ?? []
        case .picker:
            if #available(macOS 13, iOS 16, *), let item = pickerItem { return item.supportedContentTypes }
            return []
        }
    }

    /// 和 PhotosPickerItem.loadTransferable(type: Data.self) 一样用
    public func loadTransferable(type: Data.Type) async throws -> Data? {
        switch source {
        case .file(let url): return try Data(contentsOf: url)
        case .picker:
            if #available(macOS 13, iOS 16, *), let item = pickerItem { return try await item.loadTransferable(type: Data.self) }
            return nil
        }
    }
}

@available(macOS 13, iOS 16, *)
extension Binding where Value == [KLPhotoItem] {
    var pickerItems: Binding<[PhotosPickerItem]> {
        Binding<[PhotosPickerItem]>(get: { wrappedValue.compactMap(\.pickerItem) },
                                    set: { wrappedValue = $0.map(KLPhotoItem.init(picker:)) })
    }
}
#endif

#if os(macOS) && !KL_MODERN
/// macOS 12：用「打开」面板选图片（最多 max 张）
@MainActor
enum KLImageFilePanel {
    static func choose(max: Int?) -> [KLPhotoItem] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = (max ?? 2) > 1
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.prefix(max ?? .max).map(KLPhotoItem.init(file:))
    }
}
#endif

extension View {
    #if !os(iOS) && !KL_MODERN
    /// 代替 .photosPicker(isPresented:selection:maxSelectionCount:matching: .images)
    public func klPhotosPicker(isPresented: Binding<Bool>, selection: Binding<[KLPhotoItem]>, maxSelectionCount: Int? = nil) -> some View {
        modifier(KLPhotosPickerModifier(isPresented: isPresented, selection: selection, max: maxSelectionCount))
    }
    #endif
}

#if !os(iOS) && !KL_MODERN
private struct KLPhotosPickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var selection: [KLPhotoItem]
    let max: Int?

    func body(content: Content) -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13, *) {
            content.photosPicker(isPresented: $isPresented, selection: $selection.pickerItems, maxSelectionCount: max, matching: .images)
        } else {
            #if os(macOS)
            content.onChange(of: isPresented) { shown in
                guard shown else { return }
                DispatchQueue.main.async {
                    let picked = KLImageFilePanel.choose(max: max)
                    isPresented = false
                    if !picked.isEmpty { selection = picked }
                }
            }
            #else
            content
            #endif
        }
        #elseif os(iOS) || KL_MODERN
        content.photosPicker(isPresented: $isPresented, selection: $selection.pickerItems, maxSelectionCount: max, matching: .images)
        
        #else
        if #available(macOS 13, iOS 16, *) {
            content.photosPicker(isPresented: $isPresented, selection: $selection.pickerItems, maxSelectionCount: max, matching: .images)
        } else {
            #if os(macOS)
            content.onChange(of: isPresented) { shown in
                guard shown else { return }
                DispatchQueue.main.async {
                    let picked = KLImageFilePanel.choose(max: max)
                    isPresented = false
                    if !picked.isEmpty { selection = picked }
                }
            }
            #else
            content
            #endif
        }
        #endif
    }
}
#endif

#if os(iOS) || KL_MODERN
/// 主包、iPhone：直接是系统的 PhotosPicker（多选 / 单选两种，只选图片），和原来的写法一样
@MainActor
public func KLPhotosPicker<Label: View>(selection: Binding<[PhotosPickerItem]>, maxSelectionCount: Int? = nil,
                                       @ViewBuilder label: () -> Label) -> PhotosPicker<Label> {
    PhotosPicker(selection: selection, maxSelectionCount: maxSelectionCount, matching: .images, label: label)
}

@MainActor
public func KLPhotosPicker<Label: View>(selection: Binding<PhotosPickerItem?>, @ViewBuilder label: () -> Label) -> PhotosPicker<Label> {
    PhotosPicker(selection: selection, matching: .images, label: label)
}
#else
/// 代替 PhotosPicker(selection:maxSelectionCount:matching: .images) { 按钮的样子 }
public struct KLPhotosPicker<Label: View>: View {
    @Binding var selection: [KLPhotoItem]
    let maxSelectionCount: Int?
    let label: () -> Label

    public init(selection: Binding<[KLPhotoItem]>, maxSelectionCount: Int? = nil, @ViewBuilder label: @escaping () -> Label) {
        _selection = selection; self.maxSelectionCount = maxSelectionCount; self.label = label
    }

    /// 只选一张（代替 PhotosPicker(selection: Binding<PhotosPickerItem?>)）
    public init(selection single: Binding<KLPhotoItem?>, @ViewBuilder label: @escaping () -> Label) {
        _selection = Binding(get: { single.wrappedValue.map { [$0] } ?? [] }, set: { single.wrappedValue = $0.first })
        maxSelectionCount = 1; self.label = label
    }

    public var body: some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13, *) {
            PhotosPicker(selection: $selection.pickerItems, maxSelectionCount: maxSelectionCount, matching: .images, label: label)
        } else {
            #if os(macOS)
            Button {
                let picked = KLImageFilePanel.choose(max: maxSelectionCount)
                if !picked.isEmpty { selection = picked }
            } label: { label() }
            #else
            EmptyView()
            #endif
        }
        #elseif os(iOS) || KL_MODERN
        PhotosPicker(selection: $selection.pickerItems, maxSelectionCount: maxSelectionCount, matching: .images, label: label)
        
        #else
        if #available(macOS 13, iOS 16, *) {
            PhotosPicker(selection: $selection.pickerItems, maxSelectionCount: maxSelectionCount, matching: .images, label: label)
        } else {
            #if os(macOS)
            Button {
                let picked = KLImageFilePanel.choose(max: maxSelectionCount)
                if !picked.isEmpty { selection = picked }
            } label: { label() }
            #else
            EmptyView()
            #endif
        }
        #endif
    }
}
#endif
#endif

#if !os(watchOS)
// MARK: 拖放文字（draggable / dropDestination：macOS 13）

extension View {
    #if !os(iOS) && !KL_MODERN
    /// 代替 .draggable(文字)
    @ViewBuilder
    public func klDraggable(_ text: String) -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13, *) { draggable(text) } else { onDrag { NSItemProvider(object: text as NSString) } }
        #elseif os(iOS) || KL_MODERN
        draggable(text)
        #else
        if #available(macOS 13, iOS 16, *) { draggable(text) } else { onDrag { NSItemProvider(object: text as NSString) } }
        #endif
    }
    #endif

    #if !os(iOS) && !KL_MODERN
    /// 代替 .dropDestination(for: String.self) { items, location in … }
    @ViewBuilder
    public func klDropDestination(for type: String.Type, action: @escaping ([String], CGPoint) -> Bool,
                                  isTargeted: @escaping (Bool) -> Void = { _ in }) -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13, *) {
            dropDestination(for: String.self, action: action, isTargeted: isTargeted)
        } else {
            onDrop(of: [.plainText, .utf8PlainText], isTargeted: Binding(get: { false }, set: isTargeted)) { providers, location in
                let group = DispatchGroup()
                var texts: [String] = []
                for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
                    group.enter()
                    _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                        if let text = object as? String { DispatchQueue.main.async { texts.append(text) } }
                        group.leave()
                    }
                }
                group.notify(queue: .main) { if !texts.isEmpty { _ = action(texts, location) } }
                return !providers.isEmpty
            }
        }
        #elseif os(iOS) || KL_MODERN
        dropDestination(for: String.self, action: action, isTargeted: isTargeted)
        
        #else
        if #available(macOS 13, iOS 16, *) {
            dropDestination(for: String.self, action: action, isTargeted: isTargeted)
        } else {
            onDrop(of: [.plainText, .utf8PlainText], isTargeted: Binding(get: { false }, set: isTargeted)) { providers, location in
                let group = DispatchGroup()
                var texts: [String] = []
                for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
                    group.enter()
                    _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                        if let text = object as? String { DispatchQueue.main.async { texts.append(text) } }
                        group.leave()
                    }
                }
                group.notify(queue: .main) { if !texts.isEmpty { _ = action(texts, location) } }
                return !providers.isEmpty
            }
        }
        #endif
    }
    #endif
}

#endif

// MARK: 导航栈（NavigationStack：macOS 13）

#if os(iOS) || KL_MODERN
// iPhone / iPad（iOS 18 起）和 Mac 主包（macOS 14 起）直接用系统类型：编出来和不用兼容版完全一样
public typealias KLNavigationStack<Root: View> = NavigationStack<NavigationPath, Root>
#else
/// 代替 NavigationStack { … }（只用标题、工具栏，不推页面的地方）：macOS 12 上直接显示内容（Mac 的弹窗本来就没有导航栏）
public struct KLNavigationStack<Content: View>: View {
    let content: () -> Content
    public init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    public var body: some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13, *) {
            NavigationStack(root: content)
        } else {
            #if os(macOS)
            content()
            #else
            NavigationView(content: content)
            #endif
        }
        #elseif os(iOS) || KL_MODERN
        NavigationStack(root: content)
        
        #else
        if #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) {
            NavigationStack(root: content)
        } else {
            #if os(macOS)
            content()
            #else
            NavigationView(content: content)
            #endif
        }
        #endif
    }
}
#endif

// MARK: 自定义 Layout 的退路（Layout：macOS 13）

/// 拿到 content 里的每个子视图，自己排（macOS 12 上给自定义 Layout 做退路）
public struct KLChildren<Content: View, Result: View>: View {
    private let content: Content
    private let build: (_VariadicView.Children) -> Result

    public init(@ViewBuilder _ content: () -> Content, @ViewBuilder build: @escaping (_VariadicView.Children) -> Result) {
        self.content = content(); self.build = build
    }

    public var body: some View { _VariadicView.Tree(Root(build: build)) { content } }

    private struct Root: _VariadicView_UnaryViewRoot {
        let build: (_VariadicView.Children) -> Result
        func body(children: _VariadicView.Children) -> some View { build(children) }
    }
}

/// 自动换行排列的退路：macOS 12 上排成一行、放不下就横着滚
public struct KLFlowFallback<Content: View>: View {
    let spacing: CGFloat
    let content: () -> Content
    public init(spacing: CGFloat, @ViewBuilder content: @escaping () -> Content) { self.spacing = spacing; self.content = content }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) { content() }
        }
    }
}

// MARK: 逐帧刷新（NSView.displayLink：macOS 14）

#if os(macOS)
import AppKit

/// 逐帧回调：macOS 14 起用 NSView.displayLink（跟屏幕刷新走），12 / 13 用 60 帧的定时器
@MainActor
public final class KLFrameLink {
    private var link: AnyObject?
    private var timer: Timer?
    private let proxy: Proxy

    public init(view: NSView, tick: @escaping (CFTimeInterval) -> Void) {
        proxy = Proxy(tick)
        if #available(macOS 14, *) {
            let link = view.displayLink(target: proxy, selector: #selector(Proxy.step(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [proxy] _ in proxy.tick(CACurrentMediaTime()) }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    public func invalidate() {
        if #available(macOS 14, *) { (link as? CADisplayLink)?.invalidate() }
        link = nil
        timer?.invalidate()
        timer = nil
    }

    private final class Proxy: NSObject {
        let tick: (CFTimeInterval) -> Void
        init(_ tick: @escaping (CFTimeInterval) -> Void) { self.tick = tick }

        @objc func step(_ link: AnyObject) {
            if #available(macOS 14, *), let link = link as? CADisplayLink { tick(link.timestamp) } else { tick(CACurrentMediaTime()) }
        }
    }
}
#endif

// MARK: 输入框、文字（macOS 13 / 14）

#if os(iOS) || KL_MODERN
// iPhone / iPad（iOS 18 起）和 Mac 主包（macOS 14 起）直接用系统类型：编出来和不用兼容版完全一样
public typealias KLTextField = TextField<Text>
#else
/// 代替 TextField(_:text:axis:)（会自己长高的多行输入框，macOS 13）：macOS 12 上是单行输入框
public struct KLTextField: View {
    private enum Title { case key(LocalizedStringKey), text(String) }
    private let title: Title
    @Binding private var text: String
    private let axis: Axis

    public init(_ titleKey: LocalizedStringKey, text: Binding<String>, axis: Axis = .horizontal) {
        title = .key(titleKey); _text = text; self.axis = axis
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, text: Binding<String>, axis: Axis = .horizontal) {
        self.title = .text(String(title)); _text = text; self.axis = axis
    }

    public var body: some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13, *) {
            switch title {
            case .key(let key): TextField(key, text: $text, axis: axis)
            case .text(let string): TextField(string, text: $text, axis: axis)
            }
        } else {
            switch title {
            case .key(let key): TextField(key, text: $text)
            case .text(let string): TextField(string, text: $text)
            }
        }
        #elseif os(iOS) || KL_MODERN
        switch title {
        case .key(let key): TextField(key, text: $text, axis: axis)
        case .text(let string): TextField(string, text: $text, axis: axis)
        }
        
        #else
        if #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) {
            switch title {
            case .key(let key): TextField(key, text: $text, axis: axis)
            case .text(let string): TextField(string, text: $text, axis: axis)
            }
        } else {
            switch title {
            case .key(let key): TextField(key, text: $text)
            case .text(let string): TextField(string, text: $text)
            }
        }
        #endif
    }
}
#endif

extension View {
    #if !os(iOS) && !KL_MODERN
    /// 代替 .lineLimit(2...8)（macOS 13）：旧系统上只限最多行数
    @ViewBuilder
    public func klLineLimit(_ range: ClosedRange<Int>) -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13, *) { lineLimit(range) } else { lineLimit(range.upperBound) }
        #elseif os(iOS) || KL_MODERN
        lineLimit(range)
        #else
        if #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) { lineLimit(range) } else { lineLimit(range.upperBound) }
        #endif
    }
    #endif

    #if !os(iOS) && !KL_MODERN
    /// 代替 .lineLimit(1...)（macOS 13）：旧系统上不限行数
    @ViewBuilder
    public func klLineLimit(_ range: PartialRangeFrom<Int>) -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13, *) { lineLimit(range) } else { lineLimit(nil) }
        #elseif os(iOS) || KL_MODERN
        lineLimit(range)
        #else
        if #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) { lineLimit(range) } else { lineLimit(nil) }
        #endif
    }
    #endif

    #if !os(iOS) && !KL_MODERN
    /// 代替 .focusEffectDisabled()（macOS 14）：旧系统上保留系统焦点框
    @ViewBuilder
    public func klFocusEffectDisabled(_ disabled: Bool = true) -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 14, *) { focusEffectDisabled(disabled) } else { self }
        #elseif os(iOS) || KL_MODERN
        focusEffectDisabled(disabled)
        #else
        if #available(macOS 14, iOS 17, watchOS 10, tvOS 17, *) { focusEffectDisabled(disabled) } else { self }
        #endif
    }
    #endif

    #if !os(iOS) && !KL_MODERN
    /// 代替 .scrollContentBackground(_:)（macOS 13）：旧系统上不处理（列表、多行输入框保留系统底色）
    @ViewBuilder
    public func klScrollContentBackground(_ visibility: Visibility) -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13, *) { scrollContentBackground(visibility) } else { self }
        #elseif os(iOS) || KL_MODERN
        scrollContentBackground(visibility)
        #else
        if #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) { scrollContentBackground(visibility) } else { self }
        #endif
    }
    #endif

    /// 代替 .fontDesign(_:)（macOS 13）：旧系统上不处理（根上的 fontDesign 在旧系统上本来也没有）
    @ViewBuilder
    public func klFontDesign(_ design: Font.Design?) -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13, *) { fontDesign(design) } else { self }
        #elseif os(iOS) || KL_MODERN
        fontDesign(design)
        #else
        if #available(macOS 13, iOS 16.1, watchOS 9.1, tvOS 16.1, *) { fontDesign(design) } else { self }
        #endif
    }
}

// MARK: Foundation（macOS 13）

extension URL {
    /// 代替 url.host()（macOS 13）：旧系统上用老的 host 属性
    public var klHost: String? {
        if #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) { return host() }
        return host
    }
}

extension URL {
    /// 代替 url.host(percentEncoded: false)
    public var klHostDecoded: String? {
        if #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) { return host(percentEncoded: false) }
        return host
    }

    /// 代替 url.path(percentEncoded: false)
    public var klPathDecoded: String {
        if #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) { return path(percentEncoded: false) }
        return path
    }

    /// 代替 url.appending(path:)（macOS 13）
    public func klAppending(path: String) -> URL {
        if #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) { return appending(path: path) }
        return appendingPathComponent(path)
    }
}

// MARK: 滚动、过渡、弹出（macOS 13 / 13.3 / 14）
//
// 参数写法和原接口一样（.basedOnSize、.numericText()、[.medium, .large]……），只是类型换成自己的枚举：
// 原接口的参数类型在旧系统上也不存在，没法出现在函数签名里

public enum KLScrollBounce { case automatic, always, basedOnSize }
public enum KLContentMarginPlacement { case automatic, scrollContent, scrollIndicators }
public enum KLScrollDismissesKeyboard { case automatic, immediately, interactively, never }
public enum KLButtonBorderShape { case automatic, capsule, roundedRectangle }
public enum KLSymbolReplace { case replace }

public enum KLContentTransition {
    case identity, opacity, interpolate
    case numericText(countsDown: Bool)
    case symbolReplace
    public static func numericText() -> KLContentTransition { .numericText(countsDown: false) }
    public static func symbolEffect(_ effect: KLSymbolReplace) -> KLContentTransition { .symbolReplace }
}

public enum KLDetent: Hashable {
    case medium, large
    case height(CGFloat)
    case fraction(CGFloat)
}

extension View {
    #if !os(iOS) && !KL_MODERN
    /// 代替 .scrollBounceBehavior（macOS 13.3）：旧系统上照常回弹
    @ViewBuilder
    public func klScrollBounceBehavior(_ behavior: KLScrollBounce, axes: Axis.Set = [.vertical]) -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13.3, *) {
            switch behavior {
            case .automatic: scrollBounceBehavior(.automatic, axes: axes)
            case .always: scrollBounceBehavior(.always, axes: axes)
            case .basedOnSize: scrollBounceBehavior(.basedOnSize, axes: axes)
            }
        } else { self }
        #elseif os(iOS) || KL_MODERN
        switch behavior {
        case .automatic: scrollBounceBehavior(.automatic, axes: axes)
        case .always: scrollBounceBehavior(.always, axes: axes)
        case .basedOnSize: scrollBounceBehavior(.basedOnSize, axes: axes)
        }
        
        #else
        if #available(macOS 13.3, iOS 16.4, watchOS 9.4, tvOS 16.4, *) {
            switch behavior {
            case .automatic: scrollBounceBehavior(.automatic, axes: axes)
            case .always: scrollBounceBehavior(.always, axes: axes)
            case .basedOnSize: scrollBounceBehavior(.basedOnSize, axes: axes)
            }
        } else { self }
        #endif
    }
    #endif

    #if !os(iOS) && !KL_MODERN
    /// 代替 .defaultScrollAnchor(_:)（macOS 14）：旧系统上不处理（要停在底部的地方另外自己滚）
    @ViewBuilder
    public func klDefaultScrollAnchor(_ anchor: UnitPoint?) -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 14, *) { defaultScrollAnchor(anchor) } else { self }
        #elseif os(iOS) || KL_MODERN
        defaultScrollAnchor(anchor)
        #else
        if #available(macOS 14, iOS 17, watchOS 10, tvOS 17, *) { defaultScrollAnchor(anchor) } else { self }
        #endif
    }
    #endif

    #if !os(iOS) && !KL_MODERN
    /// 代替 .contentMargins(_:_:for:)（macOS 14）：旧系统上不处理
    @ViewBuilder
    public func klContentMargins(_ edges: Edge.Set = .all, _ length: CGFloat?, for placement: KLContentMarginPlacement = .automatic) -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 14, *) {
            switch placement {
            case .automatic: contentMargins(edges, length, for: .automatic)
            case .scrollContent: contentMargins(edges, length, for: .scrollContent)
            case .scrollIndicators: contentMargins(edges, length, for: .scrollIndicators)
            }
        } else { self }
        #elseif os(iOS) || KL_MODERN
        switch placement {
        case .automatic: contentMargins(edges, length, for: .automatic)
        case .scrollContent: contentMargins(edges, length, for: .scrollContent)
        case .scrollIndicators: contentMargins(edges, length, for: .scrollIndicators)
        }
        
        #else
        if #available(macOS 14, iOS 17, watchOS 10, tvOS 17, *) {
            switch placement {
            case .automatic: contentMargins(edges, length, for: .automatic)
            case .scrollContent: contentMargins(edges, length, for: .scrollContent)
            case .scrollIndicators: contentMargins(edges, length, for: .scrollIndicators)
            }
        } else { self }
        #endif
    }
    #endif

    #if !os(iOS) && !KL_MODERN
    /// 代替 .contentTransition(_:)（macOS 13；符号替换 macOS 14）：旧系统上不做过渡动画
    @ViewBuilder
    public func klContentTransition(_ transition: KLContentTransition) -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 14, iOS 17, watchOS 10, tvOS 17, *) {
            switch transition {
            case .identity: contentTransition(.identity)
            case .opacity: contentTransition(.opacity)
            case .interpolate: contentTransition(.interpolate)
            case .numericText(let down): contentTransition(.numericText(countsDown: down))
            case .symbolReplace: contentTransition(.symbolEffect(.replace))
            }
        } else if #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) {
            switch transition {
            case .identity, .symbolReplace: contentTransition(.identity)
            case .opacity: contentTransition(.opacity)
            case .interpolate: contentTransition(.interpolate)
            case .numericText(let down): contentTransition(.numericText(countsDown: down))
            }
        } else { self }
        #elseif os(iOS) || KL_MODERN
        switch transition {
        case .identity: contentTransition(.identity)
        case .opacity: contentTransition(.opacity)
        case .interpolate: contentTransition(.interpolate)
        case .numericText(let down): contentTransition(.numericText(countsDown: down))
        case .symbolReplace: contentTransition(.symbolEffect(.replace))
        }
        #else
        if #available(macOS 14, iOS 17, watchOS 10, tvOS 17, *) {
            switch transition {
            case .identity: contentTransition(.identity)
            case .opacity: contentTransition(.opacity)
            case .interpolate: contentTransition(.interpolate)
            case .numericText(let down): contentTransition(.numericText(countsDown: down))
            case .symbolReplace: contentTransition(.symbolEffect(.replace))
            }
        } else if #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) {
            switch transition {
            case .identity, .symbolReplace: contentTransition(.identity)
            case .opacity: contentTransition(.opacity)
            case .interpolate: contentTransition(.interpolate)
            case .numericText(let down): contentTransition(.numericText(countsDown: down))
            }
        } else { self }
        #endif
    }
    #endif

    #if !os(iOS) && !KL_MODERN
    /// 代替 .scrollDismissesKeyboard（macOS 13）
    @ViewBuilder
    public func klScrollDismissesKeyboard(_ mode: KLScrollDismissesKeyboard) -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13, *) {
            switch mode {
            case .automatic: scrollDismissesKeyboard(.automatic)
            case .immediately: scrollDismissesKeyboard(.immediately)
            case .interactively: scrollDismissesKeyboard(.interactively)
            case .never: scrollDismissesKeyboard(.never)
            }
        } else { self }
        #elseif os(iOS) || KL_MODERN
        switch mode {
        case .automatic: scrollDismissesKeyboard(.automatic)
        case .immediately: scrollDismissesKeyboard(.immediately)
        case .interactively: scrollDismissesKeyboard(.interactively)
        case .never: scrollDismissesKeyboard(.never)
        }
        
        #else
        if #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) {
            switch mode {
            case .automatic: scrollDismissesKeyboard(.automatic)
            case .immediately: scrollDismissesKeyboard(.immediately)
            case .interactively: scrollDismissesKeyboard(.interactively)
            case .never: scrollDismissesKeyboard(.never)
            }
        } else { self }
        #endif
    }
    #endif

    #if !os(iOS) && !KL_MODERN
    /// 代替 .presentationDetents（macOS 13）
    @ViewBuilder
    public func klPresentationDetents(_ detents: Set<KLDetent>) -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) {
            presentationDetents(Set(detents.map { detent -> PresentationDetent in
                switch detent {
                case .medium: return .medium
                case .large: return .large
                case .height(let h): return .height(h)
                case .fraction(let f): return .fraction(f)
                }
            }))
        } else { self }
        #elseif os(iOS) || KL_MODERN
        presentationDetents(Set(detents.map { detent -> PresentationDetent in
            switch detent {
            case .medium: return .medium
            case .large: return .large
            case .height(let h): return .height(h)
            case .fraction(let f): return .fraction(f)
            }
        }))
        #else
        if #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) {
            presentationDetents(Set(detents.map { detent -> PresentationDetent in
                switch detent {
                case .medium: return .medium
                case .large: return .large
                case .height(let h): return .height(h)
                case .fraction(let f): return .fraction(f)
                }
            }))
        } else { self }
        #endif
    }
    #endif

    #if !os(iOS) && !KL_MODERN
    /// 代替 .presentationDragIndicator（macOS 13）
    @ViewBuilder
    public func klPresentationDragIndicator(_ visibility: Visibility) -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13, *) { presentationDragIndicator(visibility) } else { self }
        #elseif os(iOS) || KL_MODERN
        presentationDragIndicator(visibility)
        #else
        if #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) { presentationDragIndicator(visibility) } else { self }
        #endif
    }
    #endif

    #if !os(iOS) && !KL_MODERN
    /// 代替 .listRowSeparator（Mac 上 macOS 13）
    @ViewBuilder
    public func klListRowSeparator(_ visibility: Visibility, edges: VerticalEdge.Set = .all) -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13, *) { listRowSeparator(visibility, edges: edges) } else { self }
        #elseif os(iOS) || KL_MODERN
        listRowSeparator(visibility, edges: edges)
        #else
        self
        #endif
    }
    #endif

    #if !os(iOS) && !KL_MODERN
    /// 代替 .buttonBorderShape（.capsule 在 Mac 上 macOS 14 才有）：旧系统上用默认形状
    @ViewBuilder
    public func klButtonBorderShape(_ shape: KLButtonBorderShape) -> some View {
        switch shape {
        case .automatic: buttonBorderShape(.automatic)
        case .roundedRectangle: buttonBorderShape(.roundedRectangle)
        case .capsule:
            #if os(macOS) && !KL_MODERN
            if #available(macOS 14, *) { buttonBorderShape(.capsule) } else { self }
            #elseif os(iOS) || KL_MODERN
            buttonBorderShape(.capsule)
            #else
            if #available(macOS 14, iOS 15, watchOS 10, tvOS 15, *) { buttonBorderShape(.capsule) } else { self }
            #endif
        }
    }
    #endif
}

#if os(iOS) || KL_MODERN
// iPhone / iPad（iOS 18 起）和 Mac 主包（macOS 14 起）直接用系统类型：编出来和不用兼容版完全一样
public typealias KLViewThatFits<Content: View> = ViewThatFits<Content>
#else
/// 代替 ViewThatFits（macOS 13）：macOS 12 上直接用最后一个（一般是最紧凑的那个）
public struct KLViewThatFits<Content: View>: View {
    private let axes: Axis.Set
    private let content: () -> Content

    public init(in axes: Axis.Set = [.horizontal, .vertical], @ViewBuilder content: @escaping () -> Content) {
        self.axes = axes; self.content = content
    }

    public var body: some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13, *) {
            ViewThatFits(in: axes, content: content)
        } else {
            KLChildren(content) { children in
                if let last = children.last { last }
            }
        }
        #elseif os(iOS) || KL_MODERN
        ViewThatFits(in: axes, content: content)
        
        #else
        if #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) {
            ViewThatFits(in: axes, content: content)
        } else {
            KLChildren(content) { children in
                if let last = children.last { last }
            }
        }
        #endif
    }
}
#endif

extension Color {
    /// 代替 color.resolve(in: environment).cgColor（macOS 14）：旧系统上按环境里的深浅色取 NSColor / UIColor
    public func klCGColor(in environment: EnvironmentValues) -> CGColor {
        if #available(macOS 14, iOS 17, watchOS 10, tvOS 17, *) { return resolve(in: environment).cgColor }
        #if os(macOS)
        var result = NSColor(self).cgColor
        NSAppearance(named: environment.colorScheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            result = NSColor(self).cgColor
        }
        return result
        #elseif os(iOS)
        return UIColor(self).resolvedColor(with: UITraitCollection(userInterfaceStyle: environment.colorScheme == .dark ? .dark : .light)).cgColor
        #elseif canImport(UIKit)
        return UIColor(self).cgColor
        #else
        return CGColor(gray: 0, alpha: 1)
        #endif
    }
}

// MARK: 其他零散的（macOS 13 / 14）

extension Text {
    /// Text 上的 fontDesign（返回 Text，能接着用 + 拼）：macOS 12 上不处理
    public func klFontDesign(_ design: Font.Design?) -> Text {
        if #available(macOS 13, iOS 16.1, watchOS 9.1, tvOS 16.1, *) { return fontDesign(design) }
        return self
    }
}

extension View {
    #if !os(iOS) && !KL_MODERN
    /// 代替 View 上的 .fontWeight（macOS 13）：macOS 12 上不处理（Text 自己的 .fontWeight 一直都有）
    @ViewBuilder
    public func klFontWeight(_ weight: Font.Weight?) -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13, *) { fontWeight(weight) } else { self }
        #elseif os(iOS) || KL_MODERN
        fontWeight(weight)
        #else
        if #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) { fontWeight(weight) } else { self }
        #endif
    }
    #endif

    #if !os(iOS) && !KL_MODERN
    /// 代替 .symbolEffect(.variableColor.iterative, isActive:)（macOS 14）：旧系统上不动
    @ViewBuilder
    public func klVariableColor(isActive: Bool) -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 14, *) { symbolEffect(.variableColor.iterative, isActive: isActive) } else { self }
        #elseif os(iOS) || KL_MODERN
        symbolEffect(.variableColor.iterative, isActive: isActive)
        #else
        if #available(macOS 14, iOS 17, watchOS 10, tvOS 17, *) { symbolEffect(.variableColor.iterative, isActive: isActive) } else { self }
        #endif
    }
    #endif

    #if !os(iOS) && !KL_MODERN
    /// 闪几下（透明度 0 → 1 → 0.15 → 1 → 0.15 → 1 → 0，每段 0.16 秒），trigger 变一次闪一次。
    /// 代替 .phaseAnimator([0.0, 1, 0.15, 1, 0.15, 1, 0], trigger:)（macOS 14）
    public func klFlash<T: Equatable>(trigger: T) -> some View {
        modifier(KLFlash(trigger: trigger))
    }
    #endif

}

#if !os(watchOS)
extension View {
    #if !os(iOS) && !KL_MODERN
    /// ←/→ 键（代替两个 .onKeyPress(.leftArrow / .rightArrow)，macOS 14）：旧系统上用没有标题的键盘快捷键按钮
    public func klArrowKeys(left: @escaping () -> Void, right: @escaping () -> Void) -> some View {
        modifier(KLArrowKeys(left: left, right: right))
    }
    #endif
}
#endif

private struct KLFlash<T: Equatable>: ViewModifier {
    let trigger: T
    @State private var level = 0.0
    @State private var run = 0
    private static var phases: [Double] { [1, 0.15, 1, 0.15, 1, 0] }

    func body(content: Content) -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 14, *) {
            content.phaseAnimator([0.0, 1, 0.15, 1, 0.15, 1, 0], trigger: trigger) { view, value in
                view.opacity(value)
            } animation: { _ in .easeInOut(duration: 0.16) }
        } else {
            content.opacity(level).onChange(of: trigger) { _ in
                run += 1
                let mine = run
                for (index, value) in Self.phases.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16 * Double(index)) {
                        guard run == mine else { return }
                        withAnimation(.easeInOut(duration: 0.16)) { level = value }
                    }
                }
            }
        }
        #elseif os(iOS) || KL_MODERN
        content.phaseAnimator([0.0, 1, 0.15, 1, 0.15, 1, 0], trigger: trigger) { view, value in
            view.opacity(value)
        } animation: { _ in .easeInOut(duration: 0.16) }
        
        #else
        if #available(macOS 14, iOS 17, watchOS 10, tvOS 17, *) {
            content.phaseAnimator([0.0, 1, 0.15, 1, 0.15, 1, 0], trigger: trigger) { view, value in
                view.opacity(value)
            } animation: { _ in .easeInOut(duration: 0.16) }
        } else {
            content.opacity(level).onChange(of: trigger) { _ in
                run += 1
                let mine = run
                for (index, value) in Self.phases.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16 * Double(index)) {
                        guard run == mine else { return }
                        withAnimation(.easeInOut(duration: 0.16)) { level = value }
                    }
                }
            }
        }
        #endif
    }
}

#if !os(watchOS)
private struct KLArrowKeys: ViewModifier {
    let left: () -> Void
    let right: () -> Void

    func body(content: Content) -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 14, iOS 17, tvOS 17, *) {
            content
                .onKeyPress(.leftArrow) { left(); return .handled }
                .onKeyPress(.rightArrow) { right(); return .handled }
        } else {
            content.background {
                Group {
                    Button("", action: left).keyboardShortcut(.leftArrow, modifiers: [])
                    Button("", action: right).keyboardShortcut(.rightArrow, modifiers: [])
                }
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
        #elseif os(iOS) || KL_MODERN
        content
            .onKeyPress(.leftArrow) { left(); return .handled }
            .onKeyPress(.rightArrow) { right(); return .handled }
        #else
        if #available(macOS 14, iOS 17, tvOS 17, *) {
            content
                .onKeyPress(.leftArrow) { left(); return .handled }
                .onKeyPress(.rightArrow) { right(); return .handled }
        } else {
            content.background {
                Group {
                    Button("", action: left).keyboardShortcut(.leftArrow, modifiers: [])
                    Button("", action: right).keyboardShortcut(.rightArrow, modifiers: [])
                }
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
        #endif
    }
}

#endif

#if !os(watchOS)
/// 鼠标在视图里的位置（代替 .onContinuousHover，macOS 13）：macOS 12 上只知道进出，不知道位置
public enum KLHoverPhase { case active(CGPoint), ended }

extension View {
    #if !os(iOS) && !KL_MODERN
    @ViewBuilder
    public func klOnContinuousHover(_ action: @escaping (KLHoverPhase) -> Void) -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13, *) {
            onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point): action(.active(point))
                case .ended: action(.ended)
                }
            }
        } else {
            onHover { inside in if !inside { action(.ended) } }
        }
        #elseif os(iOS) || KL_MODERN
        onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point): action(.active(point))
            case .ended: action(.ended)
            }
        }
        
        #else
        if #available(macOS 13, iOS 16, tvOS 16, *) {
            onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point): action(.active(point))
                case .ended: action(.ended)
                }
            }
        } else {
            onHover { inside in if !inside { action(.ended) } }
        }
        #endif
    }
    #endif
}

#endif

/// 横排或竖排（axis 变了不重建子视图：新系统上是 AnyLayout）。代替 AnyLayout(HStackLayout / VStackLayout)（macOS 13）
public struct KLStack<Content: View>: View {
    let axis: Axis
    let spacing: CGFloat?
    let content: () -> Content

    public init(_ axis: Axis, spacing: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.axis = axis; self.spacing = spacing; self.content = content
    }

    public var body: some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) {
            let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: spacing)) : AnyLayout(VStackLayout(spacing: spacing))
            layout { content() }
        } else if axis == .horizontal {
            HStack(spacing: spacing) { content() }
        } else {
            VStack(spacing: spacing) { content() }
        }
        #elseif os(iOS) || KL_MODERN
        let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: spacing)) : AnyLayout(VStackLayout(spacing: spacing))
        layout { content() }
        #else
        if #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) {
            let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: spacing)) : AnyLayout(VStackLayout(spacing: spacing))
            layout { content() }
        } else if axis == .horizontal {
            HStack(spacing: spacing) { content() }
        } else {
            VStack(spacing: spacing) { content() }
        }
        #endif
    }
}

/// 代替 ShareLink（macOS 13）：macOS 12 上点了弹系统的共享菜单（NSSharingServicePicker）
public struct KLShareLink<Label: View>: View {
    private let items: [Any]
    private let label: () -> Label

    public init(url: URL, @ViewBuilder label: @escaping () -> Label) { items = [url]; self.label = label }
    #if os(macOS)
    public init(image: NSImage, title: String, @ViewBuilder label: @escaping () -> Label) { items = [image, title]; self.label = label }
    #endif

    public var body: some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13, *) {
            modern
        } else {
            #if os(macOS)
            Button {
                let picker = NSSharingServicePicker(items: Array(items.prefix(1)))
                if let view = NSApp.keyWindow?.contentView {
                    let point = view.convert(NSEvent.mouseLocation, from: nil)
                    picker.show(relativeTo: NSRect(origin: view.window?.convertPoint(fromScreen: NSEvent.mouseLocation) ?? point, size: .zero), of: view, preferredEdge: .minY)
                }
            } label: { label() }
            #else
            EmptyView()
            #endif
        }
        #elseif os(iOS) || KL_MODERN
        modern
        
        #else
        if #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) {
            modern
        } else {
            #if os(macOS)
            Button {
                let picker = NSSharingServicePicker(items: Array(items.prefix(1)))
                if let view = NSApp.keyWindow?.contentView {
                    let point = view.convert(NSEvent.mouseLocation, from: nil)
                    picker.show(relativeTo: NSRect(origin: view.window?.convertPoint(fromScreen: NSEvent.mouseLocation) ?? point, size: .zero), of: view, preferredEdge: .minY)
                }
            } label: { label() }
            #else
            EmptyView()
            #endif
        }
        #endif
    }

    @available(macOS 13, iOS 16, watchOS 9, tvOS 16, *)
    @ViewBuilder
    private var modern: some View {
        if let url = items.first as? URL {
            ShareLink(item: url, label: label)
        } else {
            #if os(macOS)
            if let image = items.first as? NSImage, let title = items.last as? String {
                ShareLink(item: Image(nsImage: image), preview: SharePreview(title, image: Image(nsImage: image)), label: label)
            }
            #endif
        }
    }
}

// MARK: 工具栏（macOS 12 的工具栏里不能写 if）

extension View {
    #if !os(iOS) && !KL_MODERN
    /// 工具栏里放一个去掉玻璃底的项（代替 ToolbarItem(…).panelBare()）。
    /// macOS 12 的 ToolbarContentBuilder 不支持 if / if #available，判断放在 View 这一层做
    @ViewBuilder
    public func klBareToolbarItem<V: View>(_ placement: ToolbarItemPlacement, @ViewBuilder _ content: () -> V) -> some View {
        #if os(macOS)
        if #available(macOS 26.0, *) {
            toolbar { ToolbarItem(placement: placement) { content() }.sharedBackgroundVisibility(.hidden) }
        } else {
            toolbar { ToolbarItem(placement: placement) { content() } }
        }
        #else
        toolbar { ToolbarItem(placement: placement) { content() } }
        #endif
    }
    #endif

    #if !os(iOS) && !KL_MODERN
    /// 代替 .navigationDestination(item:destination:)（macOS 14）：旧系统上用弹出的面板显示
    @ViewBuilder
    public func klNavigationDestination<D: Hashable, C: View>(item: Binding<D?>, @ViewBuilder destination: @escaping (D) -> C) -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 14, *) {
            navigationDestination(item: item, destination: destination)
        } else {
            sheet(isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })) {
                if let value = item.wrappedValue { destination(value) }
            }
        }
        #elseif os(iOS) || KL_MODERN
        navigationDestination(item: item, destination: destination)
        
        #else
        if #available(macOS 14, iOS 17, watchOS 10, tvOS 17, *) {
            navigationDestination(item: item, destination: destination)
        } else {
            sheet(isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })) {
                if let value = item.wrappedValue { destination(value) }
            }
        }
        #endif
    }
    #endif
}

/// 只把下面几个角变圆的矩形（代替 UnevenRoundedRectangle，macOS 13）
public struct KLUnevenRoundedRectangle: InsettableShape {
    var topLeading: CGFloat = 0, bottomLeading: CGFloat = 0, bottomTrailing: CGFloat = 0, topTrailing: CGFloat = 0
    private var inset: CGFloat = 0

    public func inset(by amount: CGFloat) -> KLUnevenRoundedRectangle {
        var shape = self
        shape.inset += amount
        return shape
    }

    public init(topLeadingRadius: CGFloat = 0, bottomLeadingRadius: CGFloat = 0, bottomTrailingRadius: CGFloat = 0,
                topTrailingRadius: CGFloat = 0, style: RoundedCornerStyle = .continuous) {
        topLeading = topLeadingRadius; bottomLeading = bottomLeadingRadius; bottomTrailing = bottomTrailingRadius; topTrailing = topTrailingRadius
    }

    public func path(in rect: CGRect) -> Path {
        if #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) {
            return UnevenRoundedRectangle(topLeadingRadius: topLeading, bottomLeadingRadius: bottomLeading,
                                          bottomTrailingRadius: bottomTrailing, topTrailingRadius: topTrailing, style: .continuous)
                .inset(by: inset).path(in: rect)
        }
        let rect = rect.insetBy(dx: inset, dy: inset)
        let topLeading = max(0, self.topLeading - inset), bottomLeading = max(0, self.bottomLeading - inset)
        let bottomTrailing = max(0, self.bottomTrailing - inset), topTrailing = max(0, self.topTrailing - inset)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + topLeading, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - topTrailing, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - topTrailing, y: rect.minY + topTrailing), radius: topTrailing, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomTrailing))
        p.addArc(center: CGPoint(x: rect.maxX - bottomTrailing, y: rect.maxY - bottomTrailing), radius: bottomTrailing, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + bottomLeading, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + bottomLeading, y: rect.maxY - bottomLeading), radius: bottomLeading, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeading))
        p.addArc(center: CGPoint(x: rect.minX + topLeading, y: rect.minY + topLeading), radius: topLeading, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

// MARK: 麦克风权限（AVAudioApplication：macOS 14）

#if canImport(AVFoundation) && !os(watchOS)
import AVFoundation

public enum KLMicPermission {
    /// 弹系统授权框（问过就直接返回结果）
    public static func request() async -> Bool {
        if #available(macOS 14, iOS 17, *) { return await AVAudioApplication.requestRecordPermission() }
        #if os(macOS)
        return await AVCaptureDevice.requestAccess(for: .audio)
        #else
        return false
        #endif
    }

    /// 用户拒绝过（系统不会再弹，只能去设置里开）
    public static var denied: Bool {
        if #available(macOS 14, iOS 17, *) { return AVAudioApplication.shared.recordPermission == .denied }
        #if os(macOS)
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
        #else
        return false
        #endif
    }
}
#endif

extension View {
    /// 在修饰符链中间按条件换一段（例如按系统版本挑工具栏）：`.klApply { withToolbar($0) }`
    public func klApply<Result: View>(@ViewBuilder _ transform: (Self) -> Result) -> Result { transform(self) }
}

// MARK: Grid（macOS 13）、拖动预览、滚动位置（macOS 14）、表单样式、列表分隔线、不可选中

#if os(iOS) || KL_MODERN
// iPhone / iPad（iOS 18 起）和 Mac 主包（macOS 14 起）直接用系统类型：编出来和不用兼容版完全一样
public typealias KLGrid<Content: View> = Grid<Content>
#else
/// 代替 Grid：macOS 12 上排成一行行（KLGridRow 是 HStack），列不对齐
public struct KLGrid<Content: View>: View {
    let alignment: Alignment
    let horizontalSpacing: CGFloat?
    let verticalSpacing: CGFloat?
    let content: () -> Content

    public init(alignment: Alignment = .center, horizontalSpacing: CGFloat? = nil, verticalSpacing: CGFloat? = nil,
                @ViewBuilder content: @escaping () -> Content) {
        self.alignment = alignment; self.horizontalSpacing = horizontalSpacing; self.verticalSpacing = verticalSpacing; self.content = content
    }

    public var body: some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13, *) {
            Grid(alignment: alignment, horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing, content: content)
        } else {
            VStack(alignment: alignment.horizontal, spacing: verticalSpacing) { content() }
                .environment(\.klGridSpacing, horizontalSpacing)
        }
        #elseif os(iOS) || KL_MODERN
        Grid(alignment: alignment, horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing, content: content)
        
        #else
        if #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) {
            Grid(alignment: alignment, horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing, content: content)
        } else {
            VStack(alignment: alignment.horizontal, spacing: verticalSpacing) { content() }
                .environment(\.klGridSpacing, horizontalSpacing)
        }
        #endif
    }
}
#endif

private struct KLGridSpacingKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }
extension EnvironmentValues {
    fileprivate var klGridSpacing: CGFloat? {
        get { self[KLGridSpacingKey.self] }
        set { self[KLGridSpacingKey.self] = newValue }
    }
}

#if os(iOS) || KL_MODERN
// iPhone / iPad（iOS 18 起）和 Mac 主包（macOS 14 起）直接用系统类型：编出来和不用兼容版完全一样
public typealias KLGridRow<Content: View> = GridRow<Content>
#else
/// 代替 GridRow
public struct KLGridRow<Content: View>: View {
    let alignment: VerticalAlignment?
    let content: () -> Content
    @Environment(\.klGridSpacing) private var spacing

    public init(alignment: VerticalAlignment? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.alignment = alignment; self.content = content
    }

    public var body: some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13, *) {
            GridRow(alignment: alignment, content: content)
        } else {
            HStack(alignment: alignment ?? .center, spacing: spacing) { content() }
        }
        #elseif os(iOS) || KL_MODERN
        GridRow(alignment: alignment, content: content)
        
        #else
        if #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) {
            GridRow(alignment: alignment, content: content)
        } else {
            HStack(alignment: alignment ?? .center, spacing: spacing) { content() }
        }
        #endif
    }
}
#endif

extension View {
    #if !os(watchOS)
    #if !os(iOS) && !KL_MODERN
    /// 代替 .draggable(文字) { 拖动时的样子 }
    @ViewBuilder
    public func klDraggable<P: View>(_ text: String, @ViewBuilder preview: () -> P) -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13, *) {
            draggable(text, preview: preview)
        } else {
            onDrag({ NSItemProvider(object: text as NSString) }, preview: preview)
        }
        #elseif os(iOS) || KL_MODERN
        draggable(text, preview: preview)
        
        #else
        if #available(macOS 13, iOS 16, *) {
            draggable(text, preview: preview)
        } else {
            onDrag({ NSItemProvider(object: text as NSString) }, preview: preview)
        }
        #endif
    }
    #endif

    #endif

    #if !os(iOS) && !KL_MODERN
    /// 代替 .scrollTargetLayout()（macOS 14）：旧系统上不处理
    @ViewBuilder
    public func klScrollTargetLayout() -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 14, *) { scrollTargetLayout() } else { self }
        #elseif os(iOS) || KL_MODERN
        scrollTargetLayout()
        #else
        if #available(macOS 14, iOS 17, watchOS 10, tvOS 17, *) { scrollTargetLayout() } else { self }
        #endif
    }
    #endif

    #if !os(iOS) && !KL_MODERN
    /// 代替 .scrollPosition(id:anchor:)（macOS 14）：旧系统上只做「值变了就滚过去」，滚动时不回写
    public func klScrollPosition<ID: Hashable>(id: Binding<ID?>, anchor: UnitPoint? = nil) -> some View {
        modifier(KLScrollPosition(id: id, anchor: anchor))
    }
    #endif

    #if !os(iOS) && !KL_MODERN
    /// 代替 .formStyle(.grouped)（macOS 13）：旧系统上用默认样式
    @ViewBuilder
    public func klFormStyleGrouped() -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13, *) { formStyle(.grouped) } else { self }
        #elseif os(iOS) || KL_MODERN
        formStyle(.grouped)
        #else
        if #available(macOS 13, iOS 16, watchOS 9, tvOS 16, *) { formStyle(.grouped) } else { self }
        #endif
    }
    #endif

    #if !os(iOS) && !KL_MODERN
    /// 代替 .listSectionSeparator（Mac 上 macOS 13）
    @ViewBuilder
    public func klListSectionSeparator(_ visibility: Visibility, edges: VerticalEdge.Set = .all) -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 13, *) { listSectionSeparator(visibility, edges: edges) } else { self }
        #elseif os(iOS) || KL_MODERN
        listSectionSeparator(visibility, edges: edges)
        #else
        self
        #endif
    }
    #endif

    #if !os(iOS) && !KL_MODERN
    /// 代替 .selectionDisabled（macOS 14）：旧系统上不处理（列表行照样能选中）
    @ViewBuilder
    public func klSelectionDisabled(_ disabled: Bool = true) -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 14, *) { selectionDisabled(disabled) } else { self }
        #elseif os(iOS) || KL_MODERN
        selectionDisabled(disabled)
        #else
        if #available(macOS 14, iOS 17, watchOS 10, tvOS 17, *) { selectionDisabled(disabled) } else { self }
        #endif
    }
    #endif
}

private struct KLScrollPosition<ID: Hashable>: ViewModifier {
    @Binding var id: ID?
    let anchor: UnitPoint?

    func body(content: Content) -> some View {
        #if os(macOS) && !KL_MODERN
        if #available(macOS 14, *) {
            content.scrollPosition(id: $id, anchor: anchor)
        } else {
            ScrollViewReader { proxy in
                content.onChange(of: id) { value in
                    if let value { withAnimation { proxy.scrollTo(value, anchor: anchor) } }
                }
            }
        }
        #elseif os(iOS) || KL_MODERN
        content.scrollPosition(id: $id, anchor: anchor)
        
        #else
        if #available(macOS 14, iOS 17, watchOS 10, tvOS 17, *) {
            content.scrollPosition(id: $id, anchor: anchor)
        } else {
            ScrollViewReader { proxy in
                content.onChange(of: id) { value in
                    if let value { withAnimation { proxy.scrollTo(value, anchor: anchor) } }
                }
            }
        }
        #endif
    }
}

// MARK: - iPhone / iPad 和 Mac 主包：一律直接调系统接口
//
// iOS 最低 18，上面那些接口都有。兼容版在 iOS 上不经过自己的修饰符、条件分支、switch（多一层就可能改变排版：
// 11-24 实测 if #available 会包成 AnyView、自己的 ViewModifier 量出的高度差 3 点），编出来和直接写原接口一样

#if os(iOS) || KL_MODERN
extension KLScrollBounce {
    var native: ScrollBounceBehavior {
        switch self { case .automatic: .automatic; case .always: .always; case .basedOnSize: .basedOnSize }
    }
}

extension KLContentMarginPlacement {
    var native: ContentMarginPlacement {
        switch self { case .automatic: .automatic; case .scrollContent: .scrollContent; case .scrollIndicators: .scrollIndicators }
    }
}

extension KLScrollDismissesKeyboard {
    var native: ScrollDismissesKeyboardMode {
        switch self { case .automatic: .automatic; case .immediately: .immediately; case .interactively: .interactively; case .never: .never }
    }
}

extension KLButtonBorderShape {
    var native: ButtonBorderShape {
        switch self { case .automatic: .automatic; case .capsule: .capsule; case .roundedRectangle: .roundedRectangle }
    }
}

extension KLContentTransition {
    var native: ContentTransition {
        switch self {
        case .identity: .identity
        case .opacity: .opacity
        case .interpolate: .interpolate
        case .numericText(let down): .numericText(countsDown: down)
        case .symbolReplace: .symbolEffect(.replace)
        }
    }
}

extension KLDetent {
    var native: PresentationDetent {
        switch self { case .medium: .medium; case .large: .large; case .height(let h): .height(h); case .fraction(let f): .fraction(f) }
    }
}

extension View {
    public func klOnGeometryChange<T: Equatable>(for type: T.Type, of transform: @escaping (GeometryProxy) -> T,
                                                 action: @escaping (T) -> Void) -> some View {
        onGeometryChange(for: type, of: transform, action: action)
    }
    #if os(iOS)
    public func klOnGeometryChange<T: Equatable>(for type: T.Type, of transform: @escaping (GeometryProxy) -> T,
                                                 action: @escaping (T, T) -> Void) -> some View {
        onGeometryChange(for: type, of: transform, action: action)
    }
    #endif
    public func klOnChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping (V, V) -> Void) -> some View {
        onChange(of: value, initial: initial, action)
    }
    public func klOnChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping () -> Void) -> some View {
        onChange(of: value, initial: initial, action)
    }
    public func klMenuButtonStyle() -> some View { menuStyle(.button) }
    public func klPhotosPicker(isPresented: Binding<Bool>, selection: Binding<[KLPhotoItem]>, maxSelectionCount: Int? = nil) -> some View {
        photosPicker(isPresented: isPresented, selection: selection, maxSelectionCount: maxSelectionCount, matching: .images)
    }
    public func klDraggable(_ text: String) -> some View { draggable(text) }
    public func klDraggable<P: View>(_ text: String, @ViewBuilder preview: () -> P) -> some View { draggable(text, preview: preview) }
    public func klDropDestination(for type: String.Type, action: @escaping ([String], CGPoint) -> Bool,
                                  isTargeted: @escaping (Bool) -> Void = { _ in }) -> some View {
        dropDestination(for: String.self, action: action, isTargeted: isTargeted)
    }
    public func klLineLimit(_ range: ClosedRange<Int>) -> some View { lineLimit(range) }
    public func klLineLimit(_ range: PartialRangeFrom<Int>) -> some View { lineLimit(range) }
    public func klFocusEffectDisabled(_ disabled: Bool = true) -> some View { focusEffectDisabled(disabled) }
    public func klScrollContentBackground(_ visibility: Visibility) -> some View { scrollContentBackground(visibility) }
    public func klScrollBounceBehavior(_ behavior: KLScrollBounce, axes: Axis.Set = [.vertical]) -> some View {
        scrollBounceBehavior(behavior.native, axes: axes)
    }
    public func klDefaultScrollAnchor(_ anchor: UnitPoint?) -> some View { defaultScrollAnchor(anchor) }
    public func klContentMargins(_ edges: Edge.Set = .all, _ length: CGFloat?, for placement: KLContentMarginPlacement = .automatic) -> some View {
        contentMargins(edges, length, for: placement.native)
    }
    public func klContentTransition(_ transition: KLContentTransition) -> some View { contentTransition(transition.native) }
    public func klScrollDismissesKeyboard(_ mode: KLScrollDismissesKeyboard) -> some View { scrollDismissesKeyboard(mode.native) }
    public func klPresentationDetents(_ detents: Set<KLDetent>) -> some View { presentationDetents(Set(detents.map(\.native))) }
    public func klPresentationDragIndicator(_ visibility: Visibility) -> some View { presentationDragIndicator(visibility) }
    public func klListRowSeparator(_ visibility: Visibility, edges: VerticalEdge.Set = .all) -> some View { listRowSeparator(visibility, edges: edges) }
    public func klButtonBorderShape(_ shape: KLButtonBorderShape) -> some View { buttonBorderShape(shape.native) }
    public func klFontWeight(_ weight: Font.Weight?) -> some View { fontWeight(weight) }
    public func klVariableColor(isActive: Bool) -> some View { symbolEffect(.variableColor.iterative, isActive: isActive) }
    public func klFlash<T: Equatable>(trigger: T) -> some View {
        phaseAnimator([0.0, 1, 0.15, 1, 0.15, 1, 0], trigger: trigger) { view, value in view.opacity(value) } animation: { _ in .easeInOut(duration: 0.16) }
    }
    public func klArrowKeys(left: @escaping () -> Void, right: @escaping () -> Void) -> some View {
        onKeyPress(.leftArrow) { left(); return .handled }.onKeyPress(.rightArrow) { right(); return .handled }
    }
    public func klOnContinuousHover(_ action: @escaping (KLHoverPhase) -> Void) -> some View {
        onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point): action(.active(point))
            case .ended: action(.ended)
            }
        }
    }
    public func klBareToolbarItem<V: View>(_ placement: ToolbarItemPlacement, @ViewBuilder _ content: () -> V) -> some View {
        #if os(macOS)
        toolbar { ToolbarItem(placement: placement) { content() }.panelBare() }
        #else
        toolbar { ToolbarItem(placement: placement) { content() } }
        #endif
    }
    public func klNavigationDestination<D: Hashable, C: View>(item: Binding<D?>, @ViewBuilder destination: @escaping (D) -> C) -> some View {
        navigationDestination(item: item, destination: destination)
    }
    public func klScrollTargetLayout() -> some View { scrollTargetLayout() }
    public func klScrollPosition<ID: Hashable>(id: Binding<ID?>, anchor: UnitPoint? = nil) -> some View { scrollPosition(id: id, anchor: anchor) }
    public func klFormStyleGrouped() -> some View { formStyle(.grouped) }
    public func klListSectionSeparator(_ visibility: Visibility, edges: VerticalEdge.Set = .all) -> some View { listSectionSeparator(visibility, edges: edges) }
    public func klSelectionDisabled(_ disabled: Bool = true) -> some View { selectionDisabled(disabled) }
}
#endif
