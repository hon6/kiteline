import Foundation
import SwiftUI
import Combine
import MachO
#if canImport(Observation)
import Observation
#endif

// MARK: - 为什么有这个文件
//
// 界面数据类原来用系统的 @Observable（Observation 框架），它要 macOS 14 / iOS 17 / watchOS 10 起才有。
// Mac 版要支持 macOS 12（2015–2017 年的 Intel Mac 最高只能升到 12 / 13），所以换成这里的写法：
//
//     final class Store: KLObservable {
//         let _klRegistrar = KLRegistrar.make()
//         @Tracked var items: [Item] = []        // 原来 @Observable 里的普通存储属性
//         var cache: [String: Int] = [:]         // 原来标 @ObservationIgnored 的：去掉标记、不加 @Tracked
//     }
//
// - 新系统（macOS 14+ / iOS 17+ / watchOS 10+）：@Tracked 的读写直接调系统的 ObservationRegistrar，
//   和 @Observable 宏展开出来的代码走同一条路，SwiftUI 照常按属性自动追踪，行为、性能和原来一样。
// - 旧系统（macOS 12 / 13）：系统没有 Observation，由这里自己记「界面读了哪些属性」，属性一变就让读过它的界面重画。
//   SwiftUI 在旧系统上不会自动追踪，所以界面要包在 KLTracking 里（View 写成 KLView、body 改名 klBody 就自动包好）；
//   List / ForEach / LazyVStack 的行、sheet / popover 的内容这类「之后才执行」的闭包，里面读了数据的要自己再包一层 KLTracking。
// - 测试旧系统的逻辑不用开虚拟机：环境变量 KITELINE_LEGACY_OBSERVATION=1 在新系统上也强制走旧逻辑；
//   再加 KITELINE_LEGACY_OBSERVATION_AUDIT=<文件> 会把「界面读了数据、却没包在 KLTracking 里」的调用位置记进这个文件
//   （每个位置只记一次），照着补 KLTracking。

public enum KLObservation {
    #if os(macOS) && !KL_MODERN
    /// 走旧系统的逻辑（系统没有 Observation，或测试时强制）
    public static let legacy: Bool = {
        let forced = ProcessInfo.processInfo.environment["KITELINE_LEGACY_OBSERVATION"] == "1"
        if #available(macOS 14, iOS 17, watchOS 10, tvOS 17, *) { return forced }
        return true
    }()

    /// 记录漏包 KLTracking 的位置（只在测试时打开）
    @usableFromInline static let auditPath: String? = legacy ? ProcessInfo.processInfo.environment["KITELINE_LEGACY_OBSERVATION_AUDIT"] : nil

    /// 和系统的 withObservationTracking 一样：执行 apply，期间读过的 @Tracked 属性之后任何一个要变时调一次 onChange（只调一次）
    @discardableResult
    public static func withTracking<T>(_ apply: () -> T, onChange: @escaping @Sendable () -> Void) -> T {
        if !legacy, #available(macOS 14, iOS 17, watchOS 10, tvOS 17, *) {
            return withObservationTracking(apply, onChange: onChange)
        }
        return LegacyTracking.track(apply, onChange: onChange).value
    }

    #else
    // 主包（macOS 14+）、iPhone、手表：只有系统的 Observation 这一套
    public static let legacy = false
    @usableFromInline static let auditPath: String? = nil

    @discardableResult
    public static func withTracking<T>(_ apply: () -> T, onChange: @escaping @Sendable () -> Void) -> T {
        withObservationTracking(apply, onChange: onChange)
    }
    #endif

    /// 两个值一样就不通知（和 Swift 6.2 起 @Observable 的 shouldNotifyObservers 一致：Equatable 比 ==，引用类型比 ===）
    @usableFromInline
    static func same<V>(_ a: V, _ b: V) -> Bool {
        if let a = a as? any Equatable { return a._klEquals(b) }
        if V.self is AnyClass, let x = a as AnyObject?, let y = b as AnyObject? { return x === y }
        return false
    }
}

extension Equatable {
    fileprivate func _klEquals(_ other: Any) -> Bool {
        guard let other = other as? Self else { return false }
        return self == other
    }
}

// MARK: - 数据类

/// 界面数据类（代替 @Observable）。主包、iPhone、手表上它就是系统的 Observable（SwiftUI、@Bindable、withObservationTracking 照常认）；
/// 兼容包（macOS 12 / 13）上系统没有 Observable，只是个普通协议
#if os(macOS) && !KL_MODERN
public protocol KLObservable: AnyObject {
    var _klRegistrar: KLRegistrar { get }
}
#else
public protocol KLObservable: AnyObject, Observable {
    var _klRegistrar: KLRegistrar { get }
}
#endif

#if os(macOS) && !KL_MODERN
/// 每个数据对象一份：记谁读了哪个属性、属性变了通知谁。
/// 新系统上包着系统的 ObservationRegistrar（native），调用方式和 @Observable 宏展开的代码一样；旧系统上 native 是 nil，走自己的登记
public final class KLRegistrar: @unchecked Sendable {
    public static func make() -> KLRegistrar { KLRegistrar() }

    /// 新系统：KLNativeBox（存成 AnyObject，因为 ObservationRegistrar 在旧系统上不存在，不能直接当存储属性的类型）
    @usableFromInline let native: AnyObject?

    init() {
        if !KLObservation.legacy, #available(macOS 14, iOS 17, watchOS 10, tvOS 17, *) {
            native = KLNativeBox()
        } else {
            native = nil
        }
    }

    // 旧系统：属性 → 等它变化的追踪
    private let lock = NSLock()
    private var observers: [AnyKeyPath: [ObjectIdentifier: LegacyTracking.Token]] = [:]
    /// 旧系统：在追踪之外被界面读过的属性（SwiftUI 之后才执行的闭包里读的：ScrollView、overlay、GeometryReader 的内容……）。
    /// 它们一变就让所有界面重画一次（兜底），重画时再读到的会重新记上
    private var untracked = Set<AnyKeyPath>()

    @inlinable @inline(__always)
    public func access<Owner: AnyObject, V>(_ owner: Owner, _ keyPath: KeyPath<Owner, V>) {
        if let native, #available(macOS 14, iOS 17, watchOS 10, tvOS 17, *) {
            unsafeDowncast(native, to: KLNativeBox.self).registrar.access(KLNativeBox.subject, keyPath: KLNativeBox.key(keyPath))
        } else {
            legacyAccess(keyPath)
        }
    }

    @inlinable @inline(__always)
    public func willSet<Owner: AnyObject, V>(_ owner: Owner, _ keyPath: KeyPath<Owner, V>) {
        if let native, #available(macOS 14, iOS 17, watchOS 10, tvOS 17, *) {
            unsafeDowncast(native, to: KLNativeBox.self).registrar.willSet(KLNativeBox.subject, keyPath: KLNativeBox.key(keyPath))
        } else {
            legacyWillSet(keyPath)
        }
    }

    @inlinable @inline(__always)
    public func didSet<Owner: AnyObject, V>(_ owner: Owner, _ keyPath: KeyPath<Owner, V>) {
        if let native, #available(macOS 14, iOS 17, watchOS 10, tvOS 17, *) {
            unsafeDowncast(native, to: KLNativeBox.self).registrar.didSet(KLNativeBox.subject, keyPath: KLNativeBox.key(keyPath))
        }
    }

    /// 原地修改（_modify）前的那次读取：在追踪里照常记；不在追踪里时不算「界面读过」（是模型自己在改值）
    @inlinable @inline(__always)
    public func accessForModify<Owner: AnyObject, V>(_ owner: Owner, _ keyPath: KeyPath<Owner, V>) {
        if native != nil { access(owner, keyPath) } else if Thread.isMainThread, let frame = LegacyTracking.current { frame.record(self, keyPath) }
    }

    @usableFromInline
    func legacyAccess(_ keyPath: AnyKeyPath) {
        guard Thread.isMainThread else { return }
        if let frame = LegacyTracking.current {
            frame.record(self, keyPath)
        } else if LegacyTracking.inViewUpdate() {
            // 这一轮 SwiftUI 在算界面（有 KLTracking 刚算过），却不在任何追踪里：多半是之后才执行的闭包，记下兜底。
            // 不在算界面时的读取（按钮回调、定时器、AppKit 代码）跟界面无关，不记
            lock.lock(); untracked.insert(keyPath); lock.unlock()
            if KLObservation.auditPath != nil { LegacyTracking.audit(keyPath) }
        }
    }

    @usableFromInline
    func legacyWillSet(_ keyPath: AnyKeyPath) {
        lock.lock()
        let waiting = observers.removeValue(forKey: keyPath)
        let wasUntracked = untracked.remove(keyPath) != nil
        lock.unlock()
        waiting?.values.forEach { $0.fire() }
        if let waiting, !waiting.isEmpty, KLObservation.auditPath != nil { LegacyTracking.countRefresh(keyPath, prefix: "精确 \(waiting.count) ") }
        if wasUntracked {
            LegacyTracking.refreshAll()
            if KLObservation.auditPath != nil { LegacyTracking.countRefresh(keyPath) }
        }
    }

    func add(_ token: LegacyTracking.Token, for keyPath: AnyKeyPath) {
        lock.lock(); observers[keyPath, default: [:]][ObjectIdentifier(token)] = token; lock.unlock()
    }

    func remove(_ token: LegacyTracking.Token, for keyPath: AnyKeyPath) {
        lock.lock()
        observers[keyPath]?[ObjectIdentifier(token)] = nil
        if observers[keyPath]?.isEmpty == true { observers[keyPath] = nil }
        lock.unlock()
    }
}

/// 新系统：系统的 ObservationRegistrar。
/// 系统接口要求「对象类型: Observable」，但它只拿键路径当属性的标识（SwiftUI 和 withObservationTracking 按
/// 「哪个登记器 + 哪个键路径」记依赖），对象本身不用；所以统一传一个固定的 subject，键路径按 subject 的类型转一下，
/// 省掉每次读写都动态查一遍类型（读一次从 90ns 降到和原版同一级别）。数据类因此也不需要声明 Observable
@available(macOS 14, iOS 17, watchOS 10, tvOS 17, *)
@usableFromInline
final class KLNativeBox {
    @usableFromInline let registrar = ObservationRegistrar()
    @usableFromInline init() {}

    @usableFromInline final class Subject: Observable {}
    @usableFromInline static let subject = Subject()

    @inlinable @inline(__always)
    static func key<Owner, V>(_ keyPath: KeyPath<Owner, V>) -> KeyPath<Subject, V> {
        unsafeBitCast(keyPath, to: KeyPath<Subject, V>.self)
    }
}

#else
/// 每个数据对象一份：就是系统的 ObservationRegistrar，读写的调用和 @Observable 宏展开的代码一模一样
public final class KLRegistrar: @unchecked Sendable {
    public static func make() -> KLRegistrar { KLRegistrar() }

    @usableFromInline let registrar = ObservationRegistrar()
    @usableFromInline init() {}

    @inlinable @inline(__always)
    public func access<Owner: KLObservable, V>(_ owner: Owner, _ keyPath: KeyPath<Owner, V>) {
        registrar.access(owner, keyPath: keyPath)
    }

    @inlinable @inline(__always)
    public func accessForModify<Owner: KLObservable, V>(_ owner: Owner, _ keyPath: KeyPath<Owner, V>) {
        registrar.access(owner, keyPath: keyPath)
    }

    @inlinable @inline(__always)
    public func willSet<Owner: KLObservable, V>(_ owner: Owner, _ keyPath: KeyPath<Owner, V>) {
        registrar.willSet(owner, keyPath: keyPath)
    }

    @inlinable @inline(__always)
    public func didSet<Owner: KLObservable, V>(_ owner: Owner, _ keyPath: KeyPath<Owner, V>) {
        registrar.didSet(owner, keyPath: keyPath)
    }
}
#endif

/// 数据类里要追踪的属性（代替 @Observable 里的普通存储属性）
@propertyWrapper
public struct Tracked<Value> {
    @usableFromInline var value: Value

    @inlinable
    public init(wrappedValue: Value) { value = wrappedValue }

    @available(*, unavailable, message: "@Tracked 只能用在 KLObservable 类里")
    public var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() }
    }

    @inlinable
    public static subscript<Owner: KLObservable>(
        _enclosingInstance owner: Owner,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<Owner, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<Owner, Tracked<Value>>
    ) -> Value {
        @inline(__always) get {
            owner._klRegistrar.access(owner, wrappedKeyPath)
            return owner[keyPath: storageKeyPath].value
        }
        set {
            // 和 @Observable 一样：值没变就不通知
            guard !KLObservation.same(owner[keyPath: storageKeyPath].value, newValue) else {
                owner[keyPath: storageKeyPath].value = newValue
                return
            }
            let registrar = owner._klRegistrar
            registrar.willSet(owner, wrappedKeyPath)
            owner[keyPath: storageKeyPath].value = newValue
            registrar.didSet(owner, wrappedKeyPath)
        }
        // 原地改（数组 append、字典下标赋值……）：不复制整份值，和 @Observable 的 _modify 一样
        _modify {
            let registrar = owner._klRegistrar
            registrar.accessForModify(owner, wrappedKeyPath)
            registrar.willSet(owner, wrappedKeyPath)
            defer { registrar.didSet(owner, wrappedKeyPath) }
            yield &owner[keyPath: storageKeyPath].value
        }
    }
}

// 值是 Equatable / 引用类型时直接比较（编译期就选好这个版本），不用每次写都动态判断类型：写一次从 ~75ns 降到和原版一个量级
extension Tracked where Value: Equatable {
    @inlinable
    public static subscript<Owner: KLObservable>(
        _enclosingInstance owner: Owner,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<Owner, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<Owner, Tracked<Value>>
    ) -> Value {
        @inline(__always) get {
            owner._klRegistrar.access(owner, wrappedKeyPath)
            return owner[keyPath: storageKeyPath].value
        }
        set {
            guard owner[keyPath: storageKeyPath].value != newValue else {
                owner[keyPath: storageKeyPath].value = newValue
                return
            }
            let registrar = owner._klRegistrar
            registrar.willSet(owner, wrappedKeyPath)
            owner[keyPath: storageKeyPath].value = newValue
            registrar.didSet(owner, wrappedKeyPath)
        }
        _modify {
            let registrar = owner._klRegistrar
            registrar.accessForModify(owner, wrappedKeyPath)
            registrar.willSet(owner, wrappedKeyPath)
            defer { registrar.didSet(owner, wrappedKeyPath) }
            yield &owner[keyPath: storageKeyPath].value
        }
    }
}

extension Tracked where Value: AnyObject {
    @inlinable
    public static subscript<Owner: KLObservable>(
        _enclosingInstance owner: Owner,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<Owner, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<Owner, Tracked<Value>>
    ) -> Value {
        @inline(__always) get {
            owner._klRegistrar.access(owner, wrappedKeyPath)
            return owner[keyPath: storageKeyPath].value
        }
        set {
            guard owner[keyPath: storageKeyPath].value !== newValue else { return }
            let registrar = owner._klRegistrar
            registrar.willSet(owner, wrappedKeyPath)
            owner[keyPath: storageKeyPath].value = newValue
            registrar.didSet(owner, wrappedKeyPath)
        }
        _modify {
            let registrar = owner._klRegistrar
            registrar.accessForModify(owner, wrappedKeyPath)
            registrar.willSet(owner, wrappedKeyPath)
            defer { registrar.didSet(owner, wrappedKeyPath) }
            yield &owner[keyPath: storageKeyPath].value
        }
    }
}

// 既是 Equatable 又是引用类型：同 @Observable 宏，比 !=
extension Tracked where Value: Equatable & AnyObject {
    @inlinable
    public static subscript<Owner: KLObservable>(
        _enclosingInstance owner: Owner,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<Owner, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<Owner, Tracked<Value>>
    ) -> Value {
        @inline(__always) get {
            owner._klRegistrar.access(owner, wrappedKeyPath)
            return owner[keyPath: storageKeyPath].value
        }
        set {
            guard owner[keyPath: storageKeyPath].value != newValue else {
                owner[keyPath: storageKeyPath].value = newValue
                return
            }
            let registrar = owner._klRegistrar
            registrar.willSet(owner, wrappedKeyPath)
            owner[keyPath: storageKeyPath].value = newValue
            registrar.didSet(owner, wrappedKeyPath)
        }
        _modify {
            let registrar = owner._klRegistrar
            registrar.accessForModify(owner, wrappedKeyPath)
            registrar.willSet(owner, wrappedKeyPath)
            defer { registrar.didSet(owner, wrappedKeyPath) }
            yield &owner[keyPath: storageKeyPath].value
        }
    }
}

#if os(macOS) && !KL_MODERN
// MARK: - 旧系统的追踪

@usableFromInline
enum LegacyTracking {
    /// 正在执行的追踪（只在主线程用：SwiftUI 的 body 都在主线程算）
    @usableFromInline nonisolated(unsafe) static var current: Frame?

    @usableFromInline final class Frame {
        var seen: [(KLRegistrar, AnyKeyPath)] = []
        private var keys = Set<Key>()
        struct Key: Hashable { let registrar: ObjectIdentifier; let keyPath: AnyKeyPath }

        @usableFromInline func record(_ registrar: KLRegistrar, _ keyPath: AnyKeyPath) {
            if keys.insert(Key(registrar: ObjectIdentifier(registrar), keyPath: keyPath)).inserted {
                seen.append((registrar, keyPath))
            }
        }
    }

    /// 一次追踪：读过的属性里任何一个要变时调一次 onChange，然后自动注销
    final class Token: @unchecked Sendable {
        private let lock = NSLock()
        private var onChange: (@Sendable () -> Void)?
        private var entries: [(registrar: Weak, keyPath: AnyKeyPath)] = []
        struct Weak { weak var value: KLRegistrar? }

        init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }

        func attach(_ seen: [(KLRegistrar, AnyKeyPath)]) {
            entries = seen.map { (Weak(value: $0.0), $0.1) }
            for (registrar, keyPath) in seen { registrar.add(self, for: keyPath) }
        }

        func fire() {
            lock.lock(); let callback = onChange; onChange = nil; lock.unlock()
            guard let callback else { return }
            cancel()
            callback()
        }

        /// 不再等变化（界面重算了、换了新的追踪）
        func cancel() {
            lock.lock(); onChange = nil; let list = entries; entries = []; lock.unlock()
            for entry in list { entry.registrar.value?.remove(self, for: entry.keyPath) }
        }
    }

    /// 审计：哪些属性触发了兜底重画、各多少次（每 5 秒写一次到审计文件旁边的 .refresh 文件）
    nonisolated(unsafe) private static var refreshCounts: [String: Int] = [:]
    nonisolated(unsafe) private static var refreshDumpScheduled = false
    static func countRefresh(_ keyPath: AnyKeyPath, prefix: String = "兜底 ") {
        let name = prefix.hasPrefix("精确") ? "精确 \(keyPath)" : prefix + "\(keyPath)"
        DispatchQueue.main.async {
            refreshCounts[name, default: 0] += 1
            guard !refreshDumpScheduled, let path = KLObservation.auditPath else { return }
            refreshDumpScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                refreshDumpScheduled = false
                let text = refreshCounts.sorted { $0.value > $1.value }.map { "\($0.value)\t\($0.key)" }.joined(separator: "\n")
                try? text.write(toFile: path + ".refresh", atomically: true, encoding: .utf8)
            }
        }
    }

    /// 所有正在显示的 KLTracking（弱引用）：兜底重画用
    nonisolated(unsafe) static let views = NSHashTable<AnyObject>.weakObjects()
    nonisolated(unsafe) private static var refreshPending = false

    /// 让所有界面重画一次（同一轮里多次只做一次）
    static func refreshAll() {
        DispatchQueue.main.async {
            guard !refreshPending else { return }
            refreshPending = true
            DispatchQueue.main.async {
                refreshPending = false
                for case let box as LegacyRefreshable in views.allObjects { box.refresh() }
            }
        }
    }

    /// AttributeGraph（SwiftUI 的界面更新引擎）代码段的地址范围：调用栈里有它的地址，就是在算界面
    private static let graphRange: ClosedRange<UInt>? = {
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index), String(cString: name).contains("/AttributeGraph"),
                  let header = _dyld_get_image_header(index) else { continue }
            var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
            for _ in 0..<header.pointee.ncmds {
                let load = command.assumingMemoryBound(to: load_command.self).pointee
                if load.cmd == LC_SEGMENT_64 {
                    let segment = command.assumingMemoryBound(to: segment_command_64.self).pointee
                    let segname = withUnsafeBytes(of: segment.segname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                    if segname == "__TEXT" {
                        let start = UInt(bitPattern: header)
                        return start...(start + UInt(segment.vmsize))
                    }
                }
                command = command.advanced(by: Int(load.cmdsize))
            }
        }
        return nil
    }()

    @usableFromInline static func inViewUpdate() -> Bool {
        guard let range = graphRange else { return true }
        return Thread.callStackReturnAddresses.contains { range.contains($0.uintValue) }
    }

    static func track<T>(_ apply: () -> T, onChange: @escaping @Sendable () -> Void) -> (value: T, token: Token?) {
        guard Thread.isMainThread else { return (apply(), nil) }
        let outer = current
        let frame = Frame()
        current = frame
        let value = apply()
        current = outer
        // 嵌套时外层也算读过（和系统一致：里层读的属性变了，外层也要重算）
        if let outer { frame.seen.forEach { outer.record($0.0, $0.1) } }
        guard !frame.seen.isEmpty else { return (value, nil) }
        let token = Token(onChange: onChange)
        token.attach(frame.seen)
        return (value, token)
    }

    // 漏包 KLTracking 的位置：取调用栈里第一个 App 自己的函数（跳过这个文件和系统库），每个位置记一次
    nonisolated(unsafe) private static var audited = Set<String>()

    @usableFromInline static func audit(_ keyPath: AnyKeyPath) {
        guard let path = KLObservation.auditPath else { return }
        let symbols = Thread.callStackSymbols
        // 只关心 SwiftUI 算界面时的读取（AttributeGraph 在更新）：按钮回调、定时器里读数据不需要追踪
        guard symbols.contains(where: { $0.contains("AttributeGraph") }) else { return }
        // 跳过这个文件里的、属性的取值 / 原地修改函数（Swift 符号以 vg / vM / vr 结尾），取真正读数据的那一层和它的上一层
        func name(_ line: String) -> String { line.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).first.map(String.init) ?? line }
        let mine = symbols.dropFirst(2).map(name).filter { symbol in
            !symbol.contains("KitelineObservation") && !symbol.contains("Tracked") && !symbol.contains("KLRegistrar")
                && !symbol.contains("LegacyTracking") && !symbol.hasSuffix("vg") && !symbol.hasSuffix("vM") && !symbol.hasSuffix("vr")
                && !symbol.hasSuffix("vgTf4n_g") && !symbol.hasPrefix("$ss")
        }
        guard let first = mine.first else { return }
        let site = "\(keyPath)\t" + first + (mine.count > 1 ? "  <-  " + mine[1] : "")
        guard audited.insert("\(keyPath)" + first).inserted else { return }
        let line = site + "\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }
}

#endif

// MARK: - SwiftUI

/// 旧系统上让里面的界面按读过的数据自动重画；新系统上什么也不做（SwiftUI 自己追踪）
public struct KLTracking<Content: View>: View {
    private let content: () -> Content

    public init(@ViewBuilder _ content: @escaping () -> Content) { self.content = content }

    #if os(macOS) && !KL_MODERN
    public var body: some View {
        if KLObservation.legacy { LegacyTrackingView(content: content) } else { content() }
    }
    #else
    // iPhone / iPad / 手表的系统都自带 Observation：原样返回内容，不多包一层（见 KLView）
    public var body: Content { content() }
    #endif
}

#if os(macOS) && !KL_MODERN
protocol LegacyRefreshable: AnyObject { func refresh() }

private struct LegacyTrackingView<Content: View>: View {
    let content: () -> Content
    @StateObject private var box = Box()

    final class Box: ObservableObject, LegacyRefreshable {
        var token: LegacyTracking.Token?
        init() { LegacyTracking.views.add(self) }
        deinit { token?.cancel() }
        func refresh() { objectWillChange.send() }
    }

    var body: some View {
        box.token?.cancel()
        let result = LegacyTracking.track(content) { [weak box] in
            DispatchQueue.main.async { box?.objectWillChange.send() }
        }
        box.token = result.token
        return result.value
    }
}

#endif

/// 界面写成 KLView、把 body 改名 klBody：旧系统上自动包一层 KLTracking，新系统上和普通 View 一样
public protocol KLView: View {
    associatedtype KLBody: View
    @ViewBuilder @MainActor var klBody: KLBody { get }
}

extension KLView {
    #if os(macOS) && !KL_MODERN
    @ViewBuilder @MainActor public var body: some View {
        if KLObservation.legacy { KLTracking { klBody } } else { klBody }
    }
    #else
    // iPhone / iPad / 手表的系统都自带 Observation（iOS 17 / watchOS 10 起），用不到旧系统的追踪：
    // body 就是 klBody，不包任何东西（多包一层会改变 SwiftUI 数子视图的方式，排版跟着变）
    @MainActor public var body: KLBody { klBody }
    #endif
}

#if os(macOS) && !KL_MODERN
/// 代替 @Bindable（macOS 14 起才有）：`$x.属性` 得到 Binding
@propertyWrapper @dynamicMemberLookup
public struct KLBindable<Object: AnyObject> {
    public var wrappedValue: Object

    public init(wrappedValue: Object) { self.wrappedValue = wrappedValue }
    public init(_ object: Object) { wrappedValue = object }

    public var projectedValue: KLBindable<Object> { self }

    public subscript<V>(dynamicMember keyPath: ReferenceWritableKeyPath<Object, V>) -> Binding<V> {
        let object = wrappedValue
        return Binding(get: { object[keyPath: keyPath] }, set: { object[keyPath: keyPath] = $0 })
    }
}
#else
/// 主包、iPhone、手表：就是系统的 @Bindable
public typealias KLBindable<Object: AnyObject & Observable> = Bindable<Object>
#endif

// MARK: - macOS 14 才有的 SwiftUI 写法的兼容版

extension View {
    #if !os(iOS) && !KL_MODERN
    /// 代替 onChange(of:initial:_:)（两个参数：旧值、新值）
    public func klOnChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping (V, V) -> Void) -> some View {
        modifier(KLOnChange(value: value, initial: initial, action: action))
    }
    #endif

    #if !os(iOS) && !KL_MODERN
    /// 代替 onChange(of:initial:_:)（不要参数）
    public func klOnChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping () -> Void) -> some View {
        modifier(KLOnChange(value: value, initial: initial, action: { _, _ in action() }))
    }
    #endif
}

#if !os(iOS) && !KL_MODERN
private struct KLOnChange<V: Equatable>: ViewModifier {
    let value: V
    let initial: Bool
    let action: (V, V) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14, iOS 17, watchOS 10, tvOS 17, *) {
            content.onChange(of: value, initial: initial, action)
        } else {
            // 老接口只给新值：闭包按值捕获的 value 是上一次的值（界面重算前建的闭包）
            content
                .onAppear { if initial { action(value, value) } }
                .onChange(of: value) { [value] newValue in action(value, newValue) }
        }
    }
}
#endif

// MARK: - macOS 13 才有的 Duration 写法的兼容版

extension Task where Success == Never, Failure == Never {
    /// 代替 Task.sleep(for: .seconds(x))
    public static func sleep<T: BinaryFloatingPoint>(seconds: T) async throws {
        try await sleep(nanoseconds: UInt64(max(0, Double(seconds)) * 1_000_000_000))
    }
    public static func sleep<T: BinaryInteger>(seconds: T) async throws {
        try await sleep(nanoseconds: UInt64(max(0, Int64(seconds))) * 1_000_000_000)
    }
    /// 代替 Task.sleep(for: .milliseconds(x))
    public static func sleep<T: BinaryFloatingPoint>(milliseconds: T) async throws {
        try await sleep(nanoseconds: UInt64(max(0, Double(milliseconds)) * 1_000_000))
    }
    public static func sleep<T: BinaryInteger>(milliseconds: T) async throws {
        try await sleep(nanoseconds: UInt64(max(0, Int64(milliseconds))) * 1_000_000)
    }
}

/// ViewModifier 的同款（body(content:) 改名 klBody(content:)）
public protocol KLViewModifier: ViewModifier {
    associatedtype KLBody: View
    @ViewBuilder @MainActor func klBody(content: Content) -> KLBody
}

extension KLViewModifier {
    #if os(macOS) && !KL_MODERN
    @ViewBuilder @MainActor public func body(content: Content) -> some View {
        if KLObservation.legacy { KLTracking { klBody(content: content) } } else { klBody(content: content) }
    }
    #else
    @MainActor public func body(content: Content) -> KLBody { klBody(content: content) }
    #endif
}
