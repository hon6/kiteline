import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI
import KitelineKit

/// CGVirtualDisplay 这几个是系统私有类（BetterDisplay、DeskPad 都用它），没有头文件：用 @objc 协议声明要用的初始化方法，
/// 运行时取到类再强转过去调用（Swift 照常生成 alloc + initWith…，引用计数也对）。macOS 14～27 实测可用
@objc private protocol VirtualDisplayClass {
    init(descriptor: AnyObject)
}

@objc private protocol VirtualDisplayModeClass {
    init(width: UInt32, height: UInt32, refreshRate: Double)
}

/// 「VS Code 在虚拟屏幕中运行」：给 VS Code 建一块看不见的屏幕，把它的窗口挪过去。
///
/// Kiteline 发消息要把 VS Code 切到前台、粘贴、回车。VS Code 在虚拟屏幕上时，切到前台也不会盖住你正在用的窗口；
/// 投完再把前台还给原来的程序（键盘焦点全系统只有一个，虚拟屏幕挡不住，见 FrontReturn）。
/// - 屏幕 Kiteline 持有就在，Kiteline 退出就消失，窗口自动回到主屏幕；开关记在偏好里，下次启动自动恢复
/// - 它只放 VS Code，不能占走你的任何东西（10-31 反馈：开了虚拟屏幕程序坞没了）：
///   - 系统会把新屏幕插到两台显示器中间、把别的显示器挤开，开着镜像时还可能让它当主显示器、拉进镜像：建屏前记下排列，
///     建好照原样放回，虚拟屏幕放到外侧角上、只碰一个角；之后被系统挪了也放回去（见「屏幕」）
///   - 程序坞：虚拟屏幕放在程序坞的另一侧，万一跟过去了就换个角
///   - 没有实体显示器（合上笔记本、关了显示器）时先撤掉，不然它成了唯一的屏幕，菜单栏、程序坞、所有窗口都被搬上去
/// - 只碰一个角鼠标也滑得进去，看不见的屏幕上找不到鼠标（10-22 就这样没法用电脑了）：鼠标一进去就拉回来
/// - 窗口在虚拟屏幕上铺开、互不重叠：完全被盖住的窗口 Chromium 当作看不见、停止绘制
/// - 每个窗口原来的位置按项目记下（偏好里），移回、退出 Kiteline 时放回原处
/// - 用户自己切到 VS Code（点 Dock、⌘Tab）却一个窗口都看不到：屏幕顶部提示，一键移回
/// - 只许 VS Code 的窗口待在上面：Kiteline 自己的、别的程序的窗口跑上去就挪回来（见「只许 VS Code 待在虚拟屏幕上」）
final class VirtualScreen: ObservableObject {
    static let shared = VirtualScreen()

    @Published private(set) var isOn = false
    /// 现在在虚拟屏幕上的 VS Code 窗口数
    @Published private(set) var windowCount = 0

    private static let enabledKey = "virtualScreenEnabled"
    private static let framesKey = "virtualScreenFrames"
    /// 逻辑分辨率，1 倍、24 Hz（没人看，省显存、WindowServer 合成和 VS Code 的绘制）：够铺 4 个窗口（2×2，每个 1280×800）。
    /// 上面的窗口照样在画（Chromium 按屏幕刷新率出帧，Claude 的转圈动画一直在动），刷新率越低 WindowServer 和显卡越省
    /// （10-26 反馈：Mac 卡，当时 WindowServer 占 63% CPU、显卡 40%+）；投递靠粘贴、按键、窗口标题，不看画面。
    /// 系统最低只认 24 Hz（10-26 实测 macOS 27：10、12、15、20 都 applySettings 失败），万一不认就退回 30 Hz
    static let refreshRates = [24.0, 30.0]
    private static let width = 2560, height = 1600

    private var display: NSObject?
    private(set) var displayID: CGDirectDisplayID = 0
    private var monitors: [Any] = []
    private var fenceTimer: Timer?
    private var lastCursor: CGPoint?
    private var observers: [NSObjectProtocol] = []
    /// 「在 VS Code 中打开」刚把 VS Code 叫到前台：别弹「看不到 VS Code」的提示
    private var quietUntil = Date.distantPast
    /// Kiteline 自己的窗口最近一次在实体屏幕上的位置：被搬到虚拟屏幕上时放回这里
    private var homeFrames: [ObjectIdentifier: NSRect] = [:]
    private var strayTimer: Timer?

    /// 虚拟屏幕贴在实体显示器外侧的哪个角
    private enum Corner { case bottomRight, bottomLeft, topRight, topLeft }
    private var corner = Corner.bottomRight
    /// 这块屏幕放过的角：程序坞跟过去了就换下一个，都试过就不再挪
    private var cornersTried: Set<Corner> = []

    /// 一块实体显示器的位置、镜像谁（0 = 不镜像）；active = 能画（合上的笔记本屏幕不算）
    private struct Layout { let id: CGDirectDisplayID; let origin: CGPoint; let mirrorOf: CGDirectDisplayID; let active: Bool }
    /// 实体显示器该有的排列：建屏前记下，之后接了新显示器、你自己改了排列就以那时的为准。系统建屏时会把别的显示器挤开，
    /// 开着镜像时新屏幕还可能当上主显示器、被拉进镜像（菜单栏、程序坞、桌面一起被占走），都照这份放回去
    private var baseline: [Layout] = []
    /// 位置稳定了才往上放窗口、才查程序坞：刚建的屏幕系统还会按它记住的位置再摆，盖掉刚设的位置（10-31 实测连着三次）
    private var settled = false
    private var settleRound = 0
    /// 放了 10 次系统都不认时的样子：一直这样就不再跟它较劲（不然每两秒挪一次窗口），有新变化再试
    private var stuckAt: String?
    private var situation: String {
        "\(bounds) \(CGMainDisplayID()) " + Self.onlineDisplays().map { "\($0)>\(CGDisplayMirrorsDisplay($0))" }.joined(separator: ",")
    }
    /// 放到虚拟屏幕上的 VS Code 窗口（移回主屏幕的去掉）。系统挪屏幕时窗口不一定跟着走：留在原来的坐标上、不在任何屏幕里，
    /// 会被拽回主屏幕（10-31 实测），挪完照这份铺回去
    private var mine: [AXUIElement] = []
    private var lastPlaced = Date.distantPast
    /// 程序坞连着几次看到在虚拟屏幕上（它挪过去要一会儿，连着两次才换角）
    private var dockSightings = 0
    /// 没有实体显示器（合上笔记本、关了显示器）时先撤掉了：实体显示器回来再建
    private var suspended = false
    /// 实体显示器回来了、正等着看它稳不稳再建
    private var resuming = false
    private var lastResumed = Date.distantPast
    private var lastSuspended = Date.distantPast
    /// 建好没多久又没了几次：显示器忽有忽无时一次比一次等得久，不跟着来回建、撤（撤了 5 分钟以上再回来的从头算）
    private var flaps = 0

    /// 系统有没有虚拟屏幕接口（macOS 14 起）
    static var supported: Bool { NSClassFromString("CGVirtualDisplay") != nil }

    var bounds: CGRect { displayID == 0 ? .null : CGDisplayBounds(displayID) }

    /// 按钮的说明（鼠标停上去显示）
    var helpText: String {
        isOn ? L("VS Code 正在虚拟屏幕中运行（%@ 个窗口）：点击移回主屏幕", "\(windowCount)")
            : L("将 VS Code 移到虚拟屏幕：Kiteline 发送消息时，VS Code 不会出现在你面前")
    }

    static var needsAccessibility: String {
        L("需要先在「系统设置 → 隐私与安全性 → %@」中允许 Kiteline，才能移动 VS Code 的窗口", "\(Delivery.accessibilityName)")
    }

    // MARK: - 开关

    /// 按钮：开着就移回主屏幕，关着就移过去；结果在屏幕顶部提示一下
    func toggle() {
        if isOn {
            let count = turnOff()
            VirtualScreenHint.show(count > 0 ? L("已将 %@ 个 VS Code 窗口移回主屏幕", "\(count)") : L("已关闭虚拟屏幕"), seconds: 3)
        } else {
            turnOn { [weak self] ok, message in
                if ok {
                    VirtualScreenHint.show(message, action: L("移回")) { self?.toggle() }
                } else {
                    KitelineModel.alert(L("无法移到虚拟屏幕"), message)
                }
            }
        }
    }

    /// 打开：建屏幕、挪窗口。completion(成功, 给用户看的结果)
    func turnOn(completion: ((Bool, String) -> Void)? = nil) {
        guard !AppConfig.isolated, !Delivery.dryRun else { completion?(false, L("测试实例不创建虚拟屏幕")); return }
        guard Self.supported else { completion?(false, L("此版本的 macOS 不支持创建虚拟屏幕")); return }
        guard AXIsProcessTrusted() else { completion?(false, Self.needsAccessibility); return }
        // 一块实体显示器都没有（合着盖子开机之类）：虚拟屏幕会变成唯一的屏幕，等实体显示器出来再建
        if display == nil, physicalDisplays().isEmpty {
            AppConfig.defaults.set(true, forKey: Self.enabledKey)
            isOn = true
            suspended = true
            startObserving()
            completion?(true, L("已开启虚拟屏幕，接上显示器后自动创建"))
            return
        }
        // 建屏那一刻系统就可能把 Kiteline 的窗口搬过去：先记下它们在哪
        for window in NSApp.windows where Self.guarded(window) { remember(window) }
        if display == nil, !createDisplay() { completion?(false, L("创建虚拟屏幕失败")); return }
        AppConfig.defaults.set(true, forKey: Self.enabledKey)
        isOn = true
        startFence()
        startGuard()
        startObserving()
        // 位置稳定、系统登记好（NSScreen 更新）才能往上放窗口
        settle { [weak self] in
            guard let self, self.isOn else { return }
            guard Delivery.Editor.running() != nil else {
                completion?(true, L("已创建虚拟屏幕。VS Code 尚未运行，由 Kiteline 打开的 VS Code 窗口将放到虚拟屏幕上"))
                return
            }
            let result = self.arrange(retile: true)
            var message = result.moved > 0 ? L("已将 %@ 个 VS Code 窗口移到虚拟屏幕", "\(result.moved)") : L("VS Code 窗口已在虚拟屏幕上")
            if result.skipped > 0 { message += L("（%@ 个全屏窗口未移动，请先退出全屏）", "\(result.skipped)") }
            Log.write("虚拟屏幕：\(message)")
            completion?(true, message)
        }
    }

    /// 关闭：窗口放回原处、撤掉屏幕。返回移回了几个窗口
    @discardableResult
    func turnOff() -> Int {
        AppConfig.defaults.set(false, forKey: Self.enabledKey)
        isOn = false
        suspended = false
        stopObserving()
        let count = restoreWindows()
        evacuate()
        savedFrames = [:]
        releaseDisplay()
        Log.write("虚拟屏幕已关闭，移回 \(count) 个窗口")
        return count
    }

    /// 启动时：上次开着就恢复
    func restoreOnLaunch() {
        guard AppConfig.defaults.bool(forKey: Self.enabledKey), !AppConfig.isolated, !Delivery.dryRun else { return }
        turnOn { _, message in Log.write("启动时恢复虚拟屏幕：\(message)") }
    }

    /// 退出 Kiteline：窗口先放回原处（不然系统会随便摆到主屏幕上），开关保持，下次启动再挪过去
    func prepareForQuit() {
        guard displayID != 0 else { return }
        restoreWindows()
        evacuate()
        releaseDisplay()
    }

    // MARK: - 给别处用

    /// 「在 VS Code 中打开」：VS Code 马上会跳到前台，这次是用户要看它
    func willShowEditor() { quietUntil = Date().addingTimeInterval(4) }

    /// 「在 VS Code 中打开」切到的窗口在虚拟屏幕上：挪回原来的位置（只挪这一个，其余的留在虚拟屏幕上）
    func bringBackFocusedWindow() {
        guard isOn else { return }
        // 等 VS Code 把那个窗口切到前面
        for delay in [0.6, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.displayID != 0, let app = Delivery.Editor.running()?.app,
                      let focused = Self.attribute(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute)
                else { return }
                let window = focused as! AXUIElement
                if self.restoreWindows(only: window) > 0 {
                    Log.write("虚拟屏幕：用户要看的窗口已移回主屏幕")
                }
            }
        }
    }

    /// Kiteline 新开的 VS Code 窗口（新任务）出来后挪到虚拟屏幕；all = VS Code 是 Kiteline 拉起来的，恢复出来的窗口一起挪。
    /// 最多等 30 秒（远端窗口要先连 SSH 才有项目名）
    func adoptNewWindows(project: String, remote: Bool, all: Bool) {
        guard isOn else { return }
        let deadline = Date().addingTimeInterval(30)
        let filter: ((String) -> Bool)? = all ? nil : { Delivery.windowTitle($0, matches: project, remote: remote) }
        func poll() {
            guard isOn, Date() < deadline else { return }
            if arrange(adopt: filter).moved > 0 {
                Log.write("虚拟屏幕：已把新开的 VS Code 窗口移过去")
                if !all { return }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { poll() }
        }
        poll()
    }

    // MARK: - 屏幕

    private func createDisplay() -> Bool {
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let modeClass = NSClassFromString("CGVirtualDisplayMode"),
              let displayClass = NSClassFromString("CGVirtualDisplay") else { return false }
        // 建之前记下现有显示器的排列：系统会把新屏幕插到中间、把别的显示器挤开，还可能拉进镜像
        baseline = currentLayout()
        let descriptor = descriptorClass.init()
        descriptor.setValue(L("Kiteline 虚拟屏幕"), forKey: "name")
        descriptor.setValue(Self.width, forKey: "maxPixelsWide")
        descriptor.setValue(Self.height, forKey: "maxPixelsHigh")
        descriptor.setValue(NSValue(size: NSSize(width: 597, height: 373)), forKey: "sizeInMillimeters")
        // 厂商、型号、序列号固定：系统按这几项记这块屏幕的设置
        descriptor.setValue(0x4B4C, forKey: "vendorID")
        descriptor.setValue(0x0001, forKey: "productID")
        descriptor.setValue(1, forKey: "serialNum")
        descriptor.setValue(DispatchQueue.main, forKey: "queue")
        let terminated: @convention(block) (AnyObject?, AnyObject?) -> Void = { [weak self] _, _ in
            Log.write("虚拟屏幕被系统移除")
            self?.displayGone()
        }
        descriptor.setValue(terminated as AnyObject, forKey: "terminationHandler")
        guard let created = unsafeBitCast(displayClass, to: VirtualDisplayClass.Type.self)
                .init(descriptor: descriptor) as AnyObject as? NSObject,
              let id = (created.value(forKey: "displayID") as? NSNumber)?.uint32Value, id != 0 else { return false }
        let selector = NSSelectorFromString("applySettings:")
        typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        guard created.responds(to: selector) else { return false }
        let applied = Self.refreshRates.contains { rate in
            let mode = unsafeBitCast(modeClass, to: VirtualDisplayModeClass.Type.self)
                .init(width: UInt32(Self.width), height: UInt32(Self.height), refreshRate: rate) as AnyObject
            let settings = settingsClass.init()
            settings.setValue(0, forKey: "hiDPI")
            settings.setValue([mode], forKey: "modes")
            return unsafeBitCast(created.method(for: selector), to: Apply.self)(created, selector, settings)
        }
        guard applied else { return false }
        display = created
        displayID = id
        corner = Self.corners.first!
        cornersTried = [corner]
        settled = false
        stuckAt = nil
        place()
        Log.write("已创建虚拟屏幕 \(id)：\(CGDisplayBounds(id))")
        return true
    }

    /// 实体显示器照 baseline 放回去，虚拟屏幕放到它们外侧的角上、只碰一个角（.forAppOnly：只在 Kiteline 运行期间有效，退出即还原）。
    /// 主显示器（在原点的那块）先放；镜像跟随的显示器不设位置（设了就被拆出镜像），系统新拉的镜像先解开、原来的最后接回去
    private func place() {
        guard displayID != 0 else { return }
        fixMirrors()
        guard let target else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        for item in roots.sorted(by: { $0.origin == .zero && $1.origin != .zero }) {
            CGConfigureDisplayOrigin(config, item.id, Int32(item.origin.x), Int32(item.origin.y))
        }
        CGConfigureDisplayOrigin(config, displayID, Int32(target.x), Int32(target.y))
        let result = CGCompleteDisplayConfiguration(config, .forAppOnly)
        if result != .success {
            CGCancelDisplayConfiguration(config)
            Log.write("虚拟屏幕：调整位置失败（\(result.rawValue)）")
        }
        lastPlaced = Date()
        dockSightings = 0
    }

    /// 镜像照 baseline 改回去：虚拟屏幕自己不镜像谁，镜像它的、被系统改了的那几块改回原来的样子，别的镜像不碰。
    /// 要用 .forSession：.forAppOnly 解不开别处定下的镜像（10-31 实测）；虚拟屏幕一撤，跟它有关的镜像也就没了，不留后遗症
    private func fixMirrors() {
        let live = Dictionary(uniqueKeysWithValues: Self.onlineDisplays().map { ($0, CGDisplayMirrorsDisplay($0)) })
        let loose = live[displayID, default: kCGNullDirectDisplay] != kCGNullDirectDisplay
        let changed = baseline.filter { item in live[item.id].map { $0 != item.mirrorOf } ?? false }
        guard loose || !changed.isEmpty else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        if loose { CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay) }
        for item in changed { CGConfigureDisplayMirrorOfDisplay(config, item.id, item.mirrorOf) }
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        if result == .success {
            Log.write("虚拟屏幕：镜像被系统改了，已改回")
        } else {
            CGCancelDisplayConfiguration(config)
            Log.write("虚拟屏幕：改回镜像失败（\(result.rawValue)）")
        }
    }

    /// 要摆位置的实体显示器：能画、不是镜像跟随的
    private var roots: [Layout] { baseline.filter { $0.active && $0.mirrorOf == kCGNullDirectDisplay } }

    /// 虚拟屏幕该在的位置：实体显示器外侧的角上
    private var target: CGPoint? {
        let union = roots.reduce(CGRect.null) { $0.union(CGRect(origin: $1.origin, size: CGDisplayBounds($1.id).size)) }
        guard !union.isNull else { return nil }
        return CGPoint(x: corner == .bottomRight || corner == .topRight ? union.maxX : union.minX - CGFloat(Self.width),
                       y: corner == .bottomRight || corner == .bottomLeft ? union.maxY : union.minY - CGFloat(Self.height))
    }

    /// 系统动了不该动的：虚拟屏幕当上了主显示器、进了镜像、不在该在的角上（系统会按它记住的位置把它摆成贴着一条边，
    /// 程序坞就跟过去了），实体显示器被挤开、镜像被拆
    private var displaced: Bool {
        CGMainDisplayID() == displayID || CGDisplayIsInMirrorSet(displayID) != 0
            || roots.contains { CGDisplayBounds($0.id).origin != $0.origin }
            || baseline.contains { CGDisplayIsOnline($0.id) != 0 && CGDisplayMirrorsDisplay($0.id) != $0.mirrorOf }
            || target.map { bounds.origin != $0 } ?? false
    }

    /// 放角的先后：程序坞在侧边时，靠它那一侧的两个角往后放
    private static var corners: [Corner] {
        switch CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String {
        case "right": return [.bottomLeft, .topLeft, .bottomRight, .topRight]
        case "left": return [.bottomRight, .topRight, .bottomLeft, .topLeft]
        default: return [.bottomRight, .bottomLeft, .topRight, .topLeft]
        }
    }

    /// 现在的实体显示器排列（不含虚拟屏幕；镜像虚拟屏幕的当作不镜像）
    private func currentLayout() -> [Layout] {
        Self.onlineDisplays().filter { $0 != displayID }.map { id in
            let mirror = CGDisplayMirrorsDisplay(id)
            return Layout(id: id, origin: CGDisplayBounds(id).origin, mirrorOf: mirror == displayID ? kCGNullDirectDisplay : mirror,
                          active: CGDisplayIsActive(id) != 0)
        }
    }

    /// 等位置稳定：隔半秒看一次，连着三次都在该在的地方才算（系统登记好、NSScreen 也更新了），不对就再放一次，最多看 10 次
    private func settle(then done: @escaping () -> Void) {
        settled = false
        settleRound += 1
        let round = settleRound
        func check(_ times: Int, _ stable: Int) {
            guard displayID != 0, round == settleRound else { return }
            let ok = !displaced
            if ok, stable >= 2 {
                settled = true
                stuckAt = nil
                done()
                return
            }
            if times >= 10 {
                Log.write("虚拟屏幕：位置没能稳定在角上（\(bounds)，主显示器 \(CGMainDisplayID())），先不挪了")
                settled = true
                stuckAt = situation
                done()
                return
            }
            if !ok { place() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { check(times + 1, ok ? stable + 1 : 0) }
        }
        check(0, 0)
    }

    /// 挪虚拟屏幕：放上去的 VS Code 窗口位置稳定后铺回去（关掉了的不算）
    private func relocate() {
        place()
        settle { [weak self] in
            guard let self else { return }
            self.mine.removeAll { Self.frame($0) == nil }
            self.tile(self.mine)
            self.windowCount = self.mine.count
        }
    }

    /// 接了新显示器、拔了显示器、你在系统设置里改了排列：以现在的为准（实体显示器自己连成一片才算，被虚拟屏幕隔开的是系统挤的）；
    /// 虚拟屏幕当了主显示器、进了镜像、被挪离角上是系统动的，照原样放回。没有实体显示器了就先撤掉
    private func screensChanged() {
        guard isOn else { return }
        let physical = physicalDisplays()
        guard displayID != 0 else {
            if suspended, !physical.isEmpty { resumeLater() }
            return
        }
        if physical.isEmpty { suspend(); return }
        guard settled else { return }
        let now = currentLayout()
        let ownIDs = Set(baseline.map(\.id)) == Set(now.map(\.id))
        let untouched = CGMainDisplayID() != displayID && CGDisplayIsInMirrorSet(displayID) == 0
        if !ownIDs || (untouched && Self.contiguous(now.filter { $0.active && $0.mirrorOf == kCGNullDirectDisplay }.map { CGDisplayBounds($0.id) })) {
            baseline = now
        }
        if displaced, situation != stuckAt {
            Log.write("虚拟屏幕：显示器变化后不在该在的地方（\(bounds)，主显示器 \(CGMainDisplayID())），放回去")
            relocate()
        }
    }

    private static func contiguous(_ rects: [CGRect]) -> Bool {
        guard let first = rects.first else { return true }
        var frontier = [first], rest = Array(rects.dropFirst())
        while let current = frontier.popLast() {
            let touching = rest.filter { $0.insetBy(dx: -1, dy: -1).intersects(current) }
            rest.removeAll { rect in touching.contains(rect) }
            frontier += touching
        }
        return rest.isEmpty
    }

    /// 每两秒看一眼：被系统挪动了就放回去；程序坞跑到虚拟屏幕上了（你改了程序坞位置之类）就换个角。
    /// 程序坞在哪块屏幕，那块的可用区域就在那一边让出位置，自动隐藏时也让出几个点；顶上让出的是菜单栏，不算
    private func checkLayout() {
        guard displayID != 0, settled else { return }
        if displaced, situation != stuckAt {
            Log.write("虚拟屏幕：被挪离了角上（\(bounds)），放回去")
            relocate()
            return
        }
        guard let screen, Date().timeIntervalSince(lastPlaced) > 3 else { return }
        let frame = screen.frame, visible = screen.visibleFrame
        guard visible.minX > frame.minX || visible.maxX < frame.maxX || visible.minY > frame.minY else { dockSightings = 0; return }
        dockSightings += 1
        guard dockSightings >= 2, let next = Self.corners.first(where: { !cornersTried.contains($0) }) else { return }
        cornersTried.insert(next)
        corner = next
        Log.write("虚拟屏幕：程序坞跑到了虚拟屏幕上，换到 \(next)")
        relocate()
    }

    /// 没有实体显示器了（合上笔记本、关了显示器）：虚拟屏幕会变成唯一的屏幕，菜单栏、程序坞、所有窗口都被系统搬上去。
    /// 先撤掉，开关不变，实体显示器回来再建
    private func suspend() {
        Log.write("虚拟屏幕：没有实体显示器了，先撤掉")
        flaps = Date().timeIntervalSince(lastResumed) < 30 ? flaps + 1 : 0
        lastSuspended = Date()
        suspended = true
        releaseDisplay()
    }

    /// 实体显示器回来了：等几秒还在才建（刚撤又回来的一次比一次等得久，最多 5 分钟）
    private func resumeLater() {
        guard !resuming else { return }
        resuming = true
        if Date().timeIntervalSince(lastSuspended) > 300 { flaps = 0 }
        let wait = min(3 * pow(2, Double(flaps)), 300)
        if flaps > 0 { Log.write("虚拟屏幕：显示器忽有忽无，\(Int(wait)) 秒后再看") }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.resuming = false
            guard self.isOn, self.suspended, self.displayID == 0, !self.physicalDisplays().isEmpty else { return }
            self.suspended = false
            self.lastResumed = Date()
            Log.write("虚拟屏幕：实体显示器回来了，重新创建")
            self.turnOn()
        }
    }

    private func releaseDisplay() {
        stopFence()
        stopGuard()
        display = nil   // 放掉就消失，系统把上面的窗口挪回主屏幕
        displayID = 0
        windowCount = 0
        mine = []
    }

    /// 系统把屏幕撤了（WindowServer 重启之类）：开着的话过一会儿重建
    private func displayGone() {
        display = nil
        displayID = 0
        stopFence()
        stopGuard()
        guard isOn else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.isOn, self.display == nil else { return }
            self.turnOn()
        }
    }

    private static func activeDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    /// 实体显示器：醒着的，加上睡着的外接显示器（显示器睡眠时窗口不会被搬走，不用撤；合上的笔记本屏幕不算）。
    /// 不算虚拟屏幕自己，也不算一块显示器都没有时系统补上的替身屏（11-01 实测：关了显示器撤掉虚拟屏幕 → 系统补出替身屏 →
    /// 当成显示器回来了又建 → 替身屏随即消失又撤，每秒一轮，窗口跟着来回搬）
    private func physicalDisplays() -> [CGDirectDisplayID] {
        Self.onlineDisplays().filter { id in
            !Self.ours(id) && !Self.placeholder(id)
                && (CGDisplayIsActive(id) != 0 || (CGDisplayIsAsleep(id) != 0 && CGDisplayIsBuiltin(id) == 0))
        }
    }

    /// 虚拟屏幕（按身份认：刚放掉的那一下系统还列着它，按编号认不出来）
    private static func ours(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == 0x4B4C && CGDisplayModelNumber(id) == 0x0001
    }

    /// 系统的替身屏：厂商 "unkn"、型号 "virt"、序列号 0、没有名字，1920×1080
    private static func placeholder(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == 0x756E_6B6E && CGDisplayModelNumber(id) == 0x7669_7274
    }

    /// 连着的所有显示器，含镜像跟随、合上的笔记本屏幕
    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    // MARK: - 鼠标围栏

    private func startFence() {
        guard monitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in self?.checkCursor() }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.checkCursor()
            return event
        }) {
            monitors.append(local)
        }
        // 事件没收到的时候（别的程序抓着鼠标之类）也每半秒看一眼
        fenceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkCursor() }
    }

    private func stopFence() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        fenceTimer?.invalidate()
        fenceTimer = nil
    }

    /// 鼠标进了虚拟屏幕：拉回进去之前的位置
    private func checkCursor() {
        guard displayID != 0, let location = CGEvent(source: nil)?.location else { return }
        if bounds.contains(location) {
            let main = CGDisplayBounds(CGMainDisplayID())
            CGWarpMouseCursorPosition(lastCursor ?? CGPoint(x: main.midX, y: main.midY))
            CGAssociateMouseAndMouseCursorPosition(1)
        } else {
            lastCursor = location
        }
    }

    // MARK: - 窗口

    /// 每个项目窗口原来的位置（键是窗口标题里的项目部分，如「ccpulse [SSH: 10.168.1.10]」）
    private var savedFrames: [String: CGRect] {
        get {
            let raw = AppConfig.defaults.dictionary(forKey: Self.framesKey) as? [String: String] ?? [:]
            return raw.mapValues { NSRectFromString($0) }
        }
        set {
            if newValue.isEmpty {
                AppConfig.defaults.removeObject(forKey: Self.framesKey)
            } else {
                AppConfig.defaults.set(newValue.mapValues { NSStringFromRect($0) }, forKey: Self.framesKey)
            }
        }
    }

    /// 把 VS Code 的窗口铺到虚拟屏幕上。adopt：要从别处挪过来的窗口（nil = 全部）；
    /// 挪了新窗口或 retile 时，虚拟屏幕上的窗口重新铺一遍
    @discardableResult
    private func arrange(adopt: ((String) -> Bool)? = nil, retile: Bool = false) -> (moved: Int, skipped: Int) {
        guard displayID != 0, let app = Delivery.Editor.running()?.app else { return (0, 0) }
        var frames = savedFrames
        var placed: [AXUIElement] = []
        var moved = 0, skipped = 0, restored = 0
        for window in Self.windows(of: app) {
            guard let frame = Self.frame(window) else { continue }
            if bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) { placed.append(window); continue }
            let title = Self.title(window)
            if let adopt, !adopt(title) { continue }
            // 全屏窗口在自己的空间里，挪不了
            if Self.flag(window, "AXFullScreen") { skipped += 1; continue }
            // 最小化的先还原（动画结束后下一轮再挪），不然投递时它会在原处弹出来
            if Self.flag(window, kAXMinimizedAttribute) {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                restored += 1
                continue
            }
            let key = Self.projectKey(title)
            // 已经记过的不覆盖：Kiteline 被强制退出后窗口被系统随便摆过，记下的才是真正原来的位置
            if frames[key] == nil { frames[key] = frame }
            placed.append(window)
            moved += 1
        }
        savedFrames = frames
        if moved > 0 || retile { tile(placed) }
        // 之前放上去、这会儿被系统拽走了的也留着，下次挪屏幕时一起铺回来
        mine = placed + mine.filter { old in !placed.contains { CFEqual($0, old) } }
        windowCount = placed.count
        if restored > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.arrange(adopt: adopt) }
        }
        return (moved + restored, skipped)
    }

    /// 平铺、互不重叠：1 个占满，2～4 个两列，再多三列
    private func tile(_ windows: [AXUIElement]) {
        guard !windows.isEmpty else { return }
        let area = usableArea()
        let columns = windows.count == 1 ? 1 : (windows.count <= 4 ? 2 : 3)
        let rows = (windows.count + columns - 1) / columns
        let width = floor(area.width / CGFloat(columns)), height = floor(area.height / CGFloat(rows))
        for (index, window) in windows.enumerated() {
            let rect = CGRect(x: area.minX + CGFloat(index % columns) * width,
                              y: area.minY + CGFloat(index / columns) * height, width: width, height: height)
            Self.setFrame(window, rect)
        }
    }

    /// 虚拟屏幕上能放窗口的地方（去掉它自己的菜单栏），屏幕坐标（左上角为原点，同 AX）
    private func usableArea() -> CGRect {
        let full = bounds
        guard let primary = NSScreen.screens.first, let screen else {
            return CGRect(x: full.minX, y: full.minY + 40, width: full.width, height: full.height - 40)
        }
        let visible = screen.visibleFrame
        return CGRect(x: visible.minX, y: primary.frame.maxY - visible.maxY, width: visible.width, height: visible.height)
    }

    /// 虚拟屏幕上的窗口放回原处（only = 只放这一个）。记下的位置已经不在任何显示器上了，放到主屏幕中间
    @discardableResult
    private func restoreWindows(only: AXUIElement? = nil) -> Int {
        guard displayID != 0, let app = Delivery.Editor.running()?.app else { return 0 }
        let frames = savedFrames
        let screens = Self.activeDisplays().filter { $0 != displayID }.map { CGDisplayBounds($0) }
        let main = CGDisplayBounds(homeDisplay ?? CGMainDisplayID())
        var count = 0
        for window in only.map({ [$0] }) ?? Self.windows(of: app) {
            guard let frame = Self.frame(window), bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) else { continue }
            var target: CGRect
            if let saved = frames[Self.projectKey(Self.title(window))],
               screens.contains(where: { $0.contains(CGPoint(x: saved.midX, y: saved.midY)) }) {
                target = saved
            } else {
                let size = CGSize(width: min(frame.width, main.width - 80), height: min(frame.height, main.height - 120))
                target = CGRect(x: main.midX - size.width / 2, y: main.midY - size.height / 2, width: size.width, height: size.height)
            }
            Self.setFrame(window, target)
            mine.removeAll { CFEqual($0, window) }
            count += 1
        }
        windowCount = max(0, windowCount - count)
        return count
    }

    /// 窗口标题里的项目部分：「● 首页卡片 — ccpulse [SSH: 10.168.1.10]」→「ccpulse [SSH: 10.168.1.10]」
    private static func projectKey(_ title: String) -> String {
        title.components(separatedBy: " — ").last?.trimmingCharacters(in: .whitespaces) ?? title
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func windows(of app: NSRunningApplication) -> [AXUIElement] {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 2)
        return (attribute(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
            (attribute($0, kAXSubroleAttribute) as? String ?? kAXStandardWindowSubrole) == kAXStandardWindowSubrole
        }
    }

    private static func title(_ window: AXUIElement) -> String { attribute(window, kAXTitleAttribute) as? String ?? "" }

    private static func flag(_ window: AXUIElement, _ name: String) -> Bool { attribute(window, name) as? Bool ?? false }

    private static func frame(_ window: AXUIElement) -> CGRect? {
        guard let position = attribute(window, kAXPositionAttribute), let size = attribute(window, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    /// 先挪位置再改大小、再挪一次位置：靠近屏幕边时改大小会被系统往里推
    private static func setFrame(_ window: AXUIElement, _ rect: CGRect) {
        var origin = rect.origin, size = rect.size
        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
    }

    // MARK: - 只许 VS Code 待在虚拟屏幕上

    /// 别的窗口跑到虚拟屏幕上，用户就再也看不见、鼠标也进不去（10-25 反馈：Kiteline 自己的主窗口进去了，只剩菜单栏图标，怎么点都打不开）。
    /// 实测是两条路上去的：
    /// - 系统按厂商、型号、序列号认屏幕，再建一次就当是同一台显示器重新接上，把上次撤屏时在它上面的窗口原样搬回去（连尺寸），一次上去就次次上去
    /// - 窗口按「当前屏幕」居中、弹出时，当前屏幕可能正是虚拟屏幕（刚投递完，键盘焦点还在上面的 VS Code 里）
    /// 所以 Kiteline 自己的窗口一挪上去就放回原处；别的程序的窗口每两秒查一次，挪到主屏幕；撤屏前再清一遍，免得系统又记住它们
    private func startGuard() {
        guard strayTimer == nil else { return }
        // 系统搬窗口分两步（先挪过去，一秒多后再按记下的尺寸改大小）：建好后多看几次
        for delay in [0.2, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.evacuate() }
        }
        // 程序坞挪过去不一定有屏幕变化通知，顺带看一眼
        strayTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.evacuate()
            self?.checkLayout()
        }
    }

    private func stopGuard() {
        strayTimer?.invalidate()
        strayTimer = nil
        homeFrames = [:]
    }

    /// 要看着的 Kiteline 窗口：带标题栏的（主窗口、设置、小窗……）。纸鸢这类子窗口跟着主窗口走；
    /// 提示条、悬停说明按鼠标所在的屏幕摆（鼠标进不了虚拟屏幕），菜单栏图标那些系统的窗口更不能碰
    private static func guarded(_ window: NSWindow) -> Bool {
        window.parent == nil && window.styleMask.contains(.titled) && !window.styleMask.contains(.fullScreen)
    }

    /// 虚拟屏幕对应的 NSScreen（系统还没登记好时为 nil）
    private var screen: NSScreen? { Self.nsScreen(displayID) }

    private static func nsScreen(_ id: CGDirectDisplayID) -> NSScreen? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == id }
    }

    /// 窗口挪回哪块屏幕：主显示器；虚拟屏幕被系统当成了主显示器就换一块醒着的实体屏，一块都没有就不挪
    /// （挪了也还在虚拟屏幕上，系统再搬回来，每两秒一回：10-30 关了显示器的一夜刷了 2 万行日志）
    private var homeDisplay: CGDirectDisplayID? {
        let main = CGMainDisplayID()
        return main != displayID ? main : physicalDisplays().first { CGDisplayIsActive($0) != 0 }
    }

    /// 虚拟屏幕在 Cocoa 坐标里的范围（左下角为原点，同 NSWindow.frame）
    private var cocoaBounds: CGRect { screen?.frame ?? .null }

    /// 窗口在实体屏幕上：记下位置
    private func remember(_ window: NSWindow) {
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        guard !cocoaBounds.contains(center), NSScreen.screens.contains(where: { $0.frame.contains(center) }) else { return }
        homeFrames[ObjectIdentifier(window)] = window.frame
    }

    /// Kiteline 自己的窗口挪了、换了屏幕、出现了：在虚拟屏幕上就放回去，否则记下位置
    private func ownWindowChanged(_ window: NSWindow) {
        guard displayID != 0, Self.guarded(window) else { return }
        if !bringHome(window) { remember(window) }
    }

    /// 窗口在虚拟屏幕上：放回记下的位置（那里已经没有屏幕了就放到主屏幕中间）。返回挪没挪
    @discardableResult
    private func bringHome(_ window: NSWindow) -> Bool {
        let bounds = cocoaBounds
        guard !bounds.isNull, bounds.contains(NSPoint(x: window.frame.midX, y: window.frame.midY)) else { return false }
        var target = homeFrames[ObjectIdentifier(window)] ?? .null
        let center = NSPoint(x: target.midX, y: target.midY)
        if target.isNull || bounds.contains(center) || !NSScreen.screens.contains(where: { $0.frame.contains(center) }) {
            guard let visible = homeDisplay.flatMap(Self.nsScreen)?.visibleFrame else { return false }
            let size = NSSize(width: min(window.frame.width, visible.width - 80), height: min(window.frame.height, visible.height - 80))
            target = NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        }
        window.setFrame(target, display: window.isVisible)
        Log.write("虚拟屏幕：「\(window.title)」窗口被挪到了虚拟屏幕上，已放回")
        return true
    }

    /// 把不该在虚拟屏幕上的窗口都挪走：Kiteline 自己的放回原处，别的程序的（VS Code 系编辑器、另开的 Kiteline 测试实例除外）挪到主屏幕中间
    private func evacuate() {
        guard displayID != 0, let home = homeDisplay else { return }
        for window in NSApp.windows where Self.guarded(window) { bringHome(window) }
        let bounds = self.bounds
        let own = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var strays: [pid_t: [CGRect]] = [:]
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != own,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict),
                  bounds.contains(CGPoint(x: rect.midX, y: rect.midY)) else { continue }
            strays[pid, default: []].append(rect)
        }
        let main = CGDisplayBounds(home)
        for (pid, rects) in strays {
            // 普通 App 和菜单栏小工具（它们的设置窗口按「当前屏幕」弹，常落在这里）都挪；台前调度的缩略图、程序坞这些系统进程不动
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular || (app.activationPolicy == .accessory && !(app.bundleIdentifier?.hasPrefix("com.apple.") ?? false)),
                  app.bundleIdentifier != Bundle.main.bundleIdentifier,
                  !Delivery.Editor.known.contains(where: { $0.bundleId == app.bundleIdentifier }) else { continue }
            let ax = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(ax, 1)
            for window in Self.attribute(ax, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
                guard let frame = Self.frame(window),
                      rects.contains(where: { abs($0.minX - frame.minX) < 2 && abs($0.minY - frame.minY) < 2 }) else { continue }
                let size = CGSize(width: min(frame.width, main.width - 80), height: min(frame.height, main.height - 120))
                Self.setFrame(window, CGRect(x: main.midX - size.width / 2, y: main.midY - size.height / 2, width: size.width, height: size.height))
                Log.write("虚拟屏幕：「\(app.localizedName ?? "")」的窗口在虚拟屏幕上，已挪回主屏幕")
            }
        }
    }

    // MARK: - 用户切到 VS Code 却看不到它

    private func startObserving() {
        guard observers.isEmpty else { return }
        // Kiteline 自己的窗口：挪动、换屏幕、弹出来（按「当前屏幕」居中的那些）时看一眼
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                self?.ownWindowChanged(window)
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  Delivery.Editor.known.contains(where: { $0.bundleId == app.bundleIdentifier }) else { return }
            // 等一下再看：投递刚开始时 FrontReturn 还没记上
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.editorActivated() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  Delivery.Editor.known.contains(where: { $0.bundleId == app.bundleIdentifier }) else { return }
            self?.windowCount = 0
            self?.mine = []
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        })
    }

    private func stopObserving() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func editorActivated() {
        guard isOn, displayID != 0, !FrontReturn.busy, Date() > quietUntil,
              NSWorkspace.shared.frontmostApplication.map({ app in Delivery.Editor.known.contains { $0.bundleId == app.bundleIdentifier } }) == true,
              let app = Delivery.Editor.running()?.app else { return }
        // 屏幕上还看得到 VS Code 的窗口（用户挪回来过的）就不用提示
        let frames = Self.windows(of: app).compactMap(Self.frame)
        let hidden = frames.filter { bounds.contains(CGPoint(x: $0.midX, y: $0.midY)) }.count
        guard hidden > 0, hidden == frames.count else { return }
        VirtualScreenHint.show(L("VS Code 正在 Kiteline 的虚拟屏幕中运行"), action: L("移回主屏幕"), seconds: 10) { [weak self] in
            self?.toggle()
        }
    }
}

/// 屏幕顶部的一条提示（不抢焦点、几秒后自己消失）：挪好了 / 用户切到 VS Code 却看不到它
enum VirtualScreenHint {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ message: String, action: String? = nil, seconds: Double = 5, perform: (() -> Void)? = nil) {
        hide()
        let view = HintView(message: message, action: action, perform: { hide(); perform?() }, close: { hide() })
        let hosting = NSHostingView(rootView: view.tarsLook())
        let size = hosting.fittingSize
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // 放在鼠标所在显示器的顶部正中、菜单栏下面
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 6))
        panel.orderFrontRegardless()
        self.panel = panel
        let work = DispatchWorkItem { hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    static func hide() {
        hideWork?.cancel()
        hideWork = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private struct HintView: View {
        let message: String
        let action: String?
        let perform: () -> Void
        let close: () -> Void

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: "display").font(.app(size: 15, weight: .medium)).foregroundStyle(.secondary)
                Text(message).font(.app(size: 13, weight: .medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action, action: perform).tarsButton(prominent: true).controlSize(.small)
                }
                Button(action: close) {
                    Image(systemName: "xmark").font(.app(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("关闭")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: 560)
            .tarsGlass(cornerRadius: 20)
            .padding(10)
        }
    }
}
