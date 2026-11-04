import AppKit
import ApplicationServices

/// 投递得把 VS Code（或终端）切到前台才能粘贴、按键：先记下用户原来在用的程序，投完把前台还给它。
///
/// 键盘焦点全系统只有一个，VS Code 挪到虚拟屏幕（VirtualScreen）也躲不开切前台这一下；不还的话，
/// 在 Kiteline 里发一条消息，人就被拽到 VS Code 里去了。
/// - 投递期间用户自己切到了别的程序：还给他最后切去的那个
/// - 用户在 VS Code 里点过（想留在 VS Code）、或前台已经不是 VS Code：不动
/// - 回车这类按键要先落进 VS Code 再切回去，切早了会打进原来的程序（restore 默认等 0.4 秒）
final class FrontReturn {
    private let previous: NSRunningApplication?
    private let started = Date()
    /// 投递切过去的程序（VS Code 或终端）；nil = VS Code。前台还是它时才切回去
    var target: NSRunningApplication?
    /// 这次投递截着用户的按键（见 KeyHold）
    private var holding = false

    private init(previous: NSRunningApplication?) { self.previous = previous }

    // MARK: - 谁在前台

    private struct Activation {
        let app: NSRunningApplication
        let at: Date
    }

    /// 最近切到前台的程序（启动时开始记）
    private static var activations: [Activation] = []
    private static var observer: NSObjectProtocol?
    /// 正在投递（含投完后一小会儿）：这段时间 VS Code 跳到前台是 Kiteline 自己切的，VirtualScreen 不弹提示
    private(set) static var busyUntil = Date.distantPast
    static var busy: Bool { Date() < busyUntil }

    static func startTracking() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            activations.append(Activation(app: app, at: Date()))
            if activations.count > 32 { activations.removeFirst(activations.count - 32) }
        }
    }

    private static func isEditor(_ app: NSRunningApplication) -> Bool {
        Delivery.Editor.known.contains { $0.bundleId == app.bundleIdentifier }
    }

    private static func isSelf(_ app: NSRunningApplication) -> Bool { app.processIdentifier == getpid() }

    /// 开始投递、切前台之前调用。automation = 这次大概要多久（新任务要等新标签加载，给得长些）。
    /// holdKeys：这段时间截住用户的按键（见 KeyHold）；新任务要等十几秒，不能一直截着键盘，不截
    static func capture(automation: TimeInterval = 15, holdKeys: Bool = true) -> FrontReturn {
        busyUntil = max(busyUntil, Date().addingTimeInterval(automation))
        var front = NSWorkspace.shared.frontmostApplication
        // 菜单栏面板里点的「允许」：前台是 Kiteline 却没有窗口，还给点开面板之前在用的程序
        if let app = front, isSelf(app), !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            front = activations.last(where: { !isSelf($0.app) && !isEditor($0.app) && !$0.app.isTerminated })?.app
        }
        // 本来就在 VS Code 里：投完留在 VS Code
        if let app = front, isEditor(app) { front = nil }
        // 要切走前台的这一会儿，用户手上还在打的字先截下来，还回去以后补上（见 KeyHold）
        let result = FrontReturn(previous: front)
        if front != nil, holdKeys {
            KeyHold.begin(limit: min(automation, 8))
            result.holding = true
        }
        return result
    }

    /// delay 秒后把前台还回去；guardFor 秒内 VS Code 又自己跳到前台（新标签加载完会抢焦点）就再还一次
    func restore(after delay: TimeInterval = 0.4, guardFor: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            Self.busyUntil = Date().addingTimeInterval(1.5 + guardFor)
            let restoredAt = Date()
            giveBack()
            release()
            if guardFor > 0 { watch(since: restoredAt, for: guardFor) }
        }
    }

    /// 不还前台（留在 VS Code 给用户看、等用户点确认框）也要调：放开键盘（只放自己截的，别把别的投递正截着的放了）
    func release() {
        guard holding else { return }
        holding = false
        KeyHold.end(target: targetPID)
    }

    private var targetPID: pid_t? { (target ?? Delivery.Editor.running()?.app)?.processIdentifier }

    /// 用户在 since 之后动过鼠标键或键盘（Kiteline 自己发的按键也算，所以只在投完以后用）
    private static func userInput(since: Date, keys: Bool) -> Bool {
        let elapsed = Date().timeIntervalSince(since)
        var types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if keys { types.append(.keyDown) }
        return types.contains { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) < elapsed }
    }

    private func giveBack() {
        guard let front = NSWorkspace.shared.frontmostApplication, let targetPID,
              front.processIdentifier == targetPID else { return }   // 前台已经不是 VS Code：用户自己切走了，不动
        // VS Code 正弹着对话框：留在 VS Code。切走的话框会被盖住（系统级的还会跟着隐藏），用户在电脑前也像是它自己消失了
        if Self.isEditor(front), Delivery.editorShowsDialog(front) {
            Log.write("VS Code 正弹着对话框，前台留在 VS Code")
            return
        }
        // 投递期间用户切去过别的程序（又被投递叫回了 VS Code）：还给他最后切去的那个
        let moved = Self.activations.last { $0.at > started && $0.app.processIdentifier != targetPID && !$0.app.isTerminated }?.app
        // 没切去别处却点过鼠标：点的是 VS Code 自己，想留在 VS Code。
        // 点击被 KeyHold 截下的不算（没落到任何窗口上，还回去以后按原位置补点，点的是 VS Code 自会再切回来）
        if moved == nil && !(holding && KeyHold.heldClicks) && Self.userInput(since: started, keys: false) { return }
        guard let destination = moved ?? previous, !destination.isTerminated else { return }
        Log.write("投递完成，前台还给「\(destination.localizedName ?? "原来的程序")」")
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(destination.processIdentifier),
                                     kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if Self.isSelf(destination) {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            destination.activate()
        }
    }

    private func watch(since restoredAt: Date, for seconds: TimeInterval) {
        let center = NSWorkspace.shared.notificationCenter
        var token: NSObjectProtocol?
        token = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier == targetPID else { return }
            // 用户自己点了 VS Code、按了 ⌘Tab：不跟他抢
            guard !Self.userInput(since: restoredAt, keys: true) else {
                if let token { center.removeObserver(token) }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.giveBack() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if let token { center.removeObserver(token) }
        }
    }
}

/// 投递把 VS Code（或终端）切到前台的这一两秒，用户手上可能还在打字：在 Kiteline 里接着写下一句，或者在别的程序里打字。
/// 这些键落进 VS Code 会混进刚粘贴的消息；输入法正在拼字时，Kiteline 按的回车还会被输入法拿去上屏拼音，消息根本没发出去，
/// 下一条又接着粘在后面（10-25 实际遇到：两条拼成一条，中间夹着「mo xin」）。
/// 这段时间把用户的按键截下来（Kiteline 自己发的按键带标记，照常放行），前台还回去以后按原顺序补发给用户原来的程序。
///
/// 鼠标点击也截：点一下别的窗口，那个程序就抢走了前台，⌘V 粘进了它、回车按在空输入框上，消息没发出去
/// （11-04 实际遇到：投递时点了 MuMu 模拟器，叫回 VS Code 三次都被点走，没发成）。
/// Claude 扩展没有接口能在后台把字送进输入框（11-04 实测：辅助功能直接写输入框、替换选中文字、往 VS Code 进程直接送按键，
/// VS Code 在后台时扩展都收不到，发送按钮一直是灰的），只能切前台粘贴，所以这一两秒里不让点击改变前台。
/// 点击按原位置补点（点哪个窗口就切到哪个，只是晚一两秒）；鼠标移动、滚轮不截
enum KeyHold {
    /// Kiteline 自己发的按键（粘贴、回车、补发）带这个标记
    static let marker: Int64 = 0x4B4C_4B48
    private static var tap: CFMachPort?
    private static var source: CFRunLoopSource?
    private static var held: [CGEvent] = []
    private static var expiry: DispatchWorkItem?
    /// 自测用
    static var heldCount: Int { held.count }

    private static let mouseTypes: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                                    .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
    private static func isMouse(_ type: CGEventType) -> Bool { mouseTypes.contains(type) }
    private static func isClick(_ type: CGEventType) -> Bool { [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) }
    /// 这次截下过鼠标点击（FrontReturn 判断用户是不是点了 VS Code 想留下时用：截下的点击没落到任何窗口上）
    static var heldClicks: Bool { held.contains { isClick($0.type) } }

    /// 截到 end 为止；万一没人调 end，limit 秒后自己放开
    static func begin(limit: TimeInterval) {
        if tap == nil {
            var mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
            for type in mouseTypes { mask |= 1 << type.rawValue }
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                               eventsOfInterest: CGEventMask(mask), callback: { _, type, event, _ in
                // 回调太慢被系统停掉：接着开（这段时间漏过去的键就照常落到前台）
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = KeyHold.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                if event.getIntegerValueField(.eventSourceUserData) == KeyHold.marker { return Unmanaged.passUnretained(event) }
                if let copy = event.copy() { KeyHold.held.append(copy) }
                return nil
            }, userInfo: nil) else { return }   // 没有辅助功能权限建不起来：不截，和以前一样
            tap = port
            source = CFMachPortCreateRunLoopSource(nil, port, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        expiry?.cancel()
        let work = DispatchWorkItem { end(target: Delivery.Editor.running()?.app.processIdentifier) }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + limit, execute: work)
    }

    /// 放开键盘；截下的键等前台不再是 target（VS Code / 终端）时补发。前台一直是它（用户留在了 VS Code、或在等确认框）就不补：
    /// 补进去正是要避免的事
    static func end(target: pid_t?) {
        expiry?.cancel()
        expiry = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        source = nil
        guard !held.isEmpty else { return }
        replay(target: target, tries: 10)
    }

    /// 截着的时候按下、放开键盘以后才松开的键：松开那一下已经直接落到了前台，补发的只有按下，会一直按着。
    /// 现在实际没按着的补一个松开；修饰键（Shift、Command……）照现在实际的状态补一个
    private static func release(after events: [CGEvent]) {
        var down: [Int64: CGEvent] = [:]
        for event in events where event.type == .keyDown || event.type == .keyUp {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if event.type == .keyDown { down[code] = event } else { down[code] = nil }
        }
        for (code, event) in down where !CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code)) {
            guard let up = event.copy() else { continue }
            up.type = .keyUp
            up.setIntegerValueField(.eventSourceUserData, value: marker)
            up.post(tap: .cghidEventTap)
        }
        // 鼠标键同理：截着时按下、放开后才松开的，松开那下已经直接过去了，补一个松开
        var pressed: [Int64: CGEvent] = [:]
        for event in events where isMouse(event.type) {
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown: pressed[button] = event
            case .leftMouseUp, .rightMouseUp, .otherMouseUp: pressed[button] = nil
            default: break
            }
        }
        for (button, event) in pressed {
            guard let cgButton = CGMouseButton(rawValue: UInt32(button)),
                  !CGEventSource.buttonState(.hidSystemState, button: cgButton), let up = event.copy() else { continue }
            up.type = event.type == .leftMouseDown ? .leftMouseUp : event.type == .rightMouseDown ? .rightMouseUp : .otherMouseUp
            up.setIntegerValueField(.eventSourceUserData, value: marker)
            up.post(tap: .cghidEventTap)
        }
        let modifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn, .maskAlphaShift]
        if let last = events.last(where: { $0.type == .flagsChanged }), let fix = last.copy() {
            let now = CGEventSource.flagsState(.hidSystemState)
            guard last.flags.intersection(modifiers) != now.intersection(modifiers) else { return }
            fix.flags = now
            fix.setIntegerValueField(.eventSourceUserData, value: marker)
            fix.post(tap: .cghidEventTap)
        }
    }

    /// 按原顺序补发；松开鼠标键后停 0.15 秒，等点中的程序切到前台、接住焦点，后面的按键才落得进去
    private static func post(_ events: [CGEvent], from index: Int, done: @escaping () -> Void) {
        var i = index
        while i < events.count {
            let event = events[i]
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            event.post(tap: .cghidEventTap)
            i += 1
            if [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(event.type), i < events.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { post(events, from: i, done: done) }
                return
            }
        }
        done()
    }

    /// 刚叫别的程序回前台，系统要一小会儿才切过去：每 0.05 秒看一次，最多等半秒
    private static func replay(target: pid_t?, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard tap == nil else { return }   // 下一条投递又开始截了：留到它结束一起补
            let front = NSWorkspace.shared.frontmostApplication
            // 截下过点击的：点在哪个窗口由点击自己决定，不用等 VS Code 让出前台（前台还没还走也照样补，点哪儿切哪儿）
            if heldClicks || (front.map { $0.processIdentifier != target } ?? false) {
                // 程序刚回到前台，要一会儿才把键盘焦点交回输入框：补早了字会丢（Windows 版实测过）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    guard tap == nil, !held.isEmpty else { return }
                    let events = held
                    held = []
                    // 补点击会把指针挪到当时点的位置：补完挪回现在的位置
                    let pointer = events.contains { isMouse($0.type) } ? CGEvent(source: nil)?.location : nil
                    post(events, from: 0) {
                        if let pointer { CGWarpMouseCursorPosition(pointer); CGAssociateMouseAndMouseCursorPosition(1) }
                        release(after: events)
                        let keys = events.filter { $0.type == .keyDown }.count, clicks = events.filter { isClick($0.type) }.count
                        let what = [keys > 0 ? "\(keys) 次按键" : nil, clicks > 0 ? "\(clicks) 次鼠标点击" : nil].compactMap { $0 }.joined(separator: "、")
                        let now = NSWorkspace.shared.frontmostApplication?.localizedName ?? "原来的程序"
                        Log.write("投递期间截下 \(what)，已补发（现在前台是「\(now)」）")
                    }
                }
            } else if tries > 0 {
                replay(target: target, tries: tries - 1)
            } else {
                Log.write("投递期间截下 \(held.filter { $0.type == .keyDown }.count) 次按键，前台仍是 \(front?.localizedName ?? "VS Code")，不补发")
                held = []
            }
        }
    }
}
