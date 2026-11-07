#if (DEBUG || SNAPSHOT) && os(iOS)
import ActivityKit
import SwiftUI
import UIKit
#if canImport(Translation)
import Translation
#endif

/// 只在调试版、截图版里：从 Mac 上发 Darwin 通知遥控 App（点不了屏幕时测排版用）。
///   模拟器：xcrun simctl spawn <设备> notifyutil -p tars.demo.<动作>
///   真机：  xcrun devicectl device notification post --device <设备> --name tars.demo.<动作>
/// 动作：sidebar.hide / sidebar.show = 收起、拉出左栏（同点左上角的侧栏按钮）；rotate.landscape / rotate.portrait = 转屏（iPad 真机上系统不让 App 自己转）；
/// dump = 把窗口大小、各个滚动区的位置、大小、内容高、滚到哪写进 TARS_DEMO_DUMP（默认 App 的 Library/Caches/remote-dump.txt，
/// 真机用 devicectl device copy from --domain-type appDataContainer 取回来）；
/// cmd = 执行 Library/Caches/remote-cmd.txt 里的一行（真机用 devicectl device copy to 放进去）：
///   open <会话标题> / split <会话标题> / route today|usage|history|projects|inbox|todos|favorites|schedules|overview / back / home
///   page <会话标题> = 打开这个会话里最近一张网页卡片（agent_page）
///   link <网址> = 当作点了这条提示词链接（kiteline://new#p=… 或 https://tars.betac.cn/new#…，见 PromptLink）
///   live <content-state JSON> | live end = 照电脑推来的内容在本机开 / 更新 / 结束实时活动（模拟器收不到实时活动推送，看排版用）
///   dragpane <从第几块> <到第几块> <center|leading|trailing|top|bottom> [停几秒] = 照手势拖分屏的标题条；panes = 分屏现在的样子写进 remote-panes.txt
///   list [hide] = 横着的 iPhone 拉出 / 收起浮着的会话列表；settings = 横着的 iPhone 在浮着的列表里打开设置；
///   hint topLeft|topRight|portrait = 当作手里的手机转到那个方向（看转屏提示，见 RotationHint）
///   （这几样由 MainView 接，见 command）；scroll <第几个滚动区> <点数> = 把那个滚动区往下滚（负数往上）；focus = 点进输入框（弹出键盘）
///   world / flow = 打开世界模式 / 数据流大屏（会话列表接）；worldjs <脚本> = 在世界网页里执行一段脚本（如 World.openSession(key)）
///   inbound <路径> = 当作别的 App「用其他应用打开」发来这个文件（弹发送面板，见 InboundShare）；
///   inboundsend session|project <补充说明> = 在发送面板里填好说明、点「发送」（发给选中的会话 / 第一个项目新建会话）；
///   openfile / sharefile <会话 key> <路径> = 当作在消息里点了这个文件路径 / 长按「转发文件」（见 FileOpener；InboundShareHost 接）
///   route <IP>...（以数字开头或带冒号）= 每个地址走哪张网卡、算不算直连 / 走隧道（记进 remote-notes.txt）；free on|off = 模拟免费版开 / 关
///   translated = 每条翻译的状态、试过的服务和失败原因、语言包状态记进 remote-notes.txt
///   tap <按钮上的字> = 点一下这个按钮（同 VoiceOver 双击，走无障碍的「激活」；先找字完全一样的，没有再找以它开头的）；
///   labels = 屏幕上能点的东西的字记进 remote-notes.txt（tap 找不到时看看叫什么）；type <文字> = 往第一个输入框里打字（筛选框、搜索框）
private extension UIView {
    func superview<T: UIView>(of type: T.Type) -> T? {
        var view = superview
        while let current = view {
            if let match = current as? T { return match }
            view = current.superview
        }
        return nil
    }
}

enum DebugRemote {
    static let actions = ["sidebar.hide", "sidebar.show", "rotate.landscape", "rotate.portrait", "dump", "cmd"]
    /// live 命令：照电脑推来的内容在本机开 / 更新 / 结束实时活动（看锁屏卡片和灵动岛的排版）
    private static func live(_ arg: String) async {
        #if targetEnvironment(macCatalyst)
        note("截图版（Mac Catalyst）没有实时活动")   // ActivityKit 在 Mac Catalyst 上不可用
        #else
        if arg == "end" {
            for activity in Activity<KitelineLiveAttributes>.activities { await activity.end(nil, dismissalPolicy: .immediate) }
            return
        }
        let state: KitelineLiveAttributes.ContentState
        do {
            state = try JSONDecoder().decode(KitelineLiveAttributes.ContentState.self, from: Data(arg.utf8))
        } catch {
            note("live 内容解析不了：\(error)")
            return
        }
        let content = ActivityContent(state: state, staleDate: nil)
        if let current = Activity<KitelineLiveAttributes>.activities.first {
            await current.update(content)
            note("live 已更新 \(current.id)")
        } else {
            do {
                let activity = try Activity.request(attributes: KitelineLiveAttributes(host: "Mac Studio"), content: content)
                note("live 已开始 \(activity.id)，系统允许实时活动：\(ActivityAuthorizationInfo().areActivitiesEnabled)")
            } catch {
                note("live 开不了：\(error)，系统允许实时活动：\(ActivityAuthorizationInfo().areActivitiesEnabled)")
            }
        }
        #endif
    }

    /// SwiftUI 只在开着辅助功能时才建无障碍节点：照 XCTest 的做法在本进程里打开（第一次要等一会儿节点才建好）
    @MainActor private static var accessibilityOn = false
    @MainActor private static func withAccessibility(_ body: @escaping @MainActor () -> Void) {
        guard !accessibilityOn else { body(); return }
        accessibilityOn = true
        if let lib = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW) {
            typealias Setter = @convention(c) (Int32) -> Void
            for name in ["_AXSSetAutomationEnabled", "_AXSApplicationAccessibilitySetEnabled"] {
                if let symbol = dlsym(lib, name) { unsafeBitCast(symbol, to: Setter.self)(1) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { body() }
    }

    /// 各窗口里的无障碍元素（SwiftUI 的按钮、行、工具栏按钮都在里面），最上面的窗口在前
    @MainActor private static func accessibilityNodes() -> [NSObject] {
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: NSObject, _ depth: Int) {
            guard depth < 300, seen.insert(ObjectIdentifier(node)).inserted else { return }
            if node.accessibilityLabel?.isEmpty == false { out.append(node) }
            var kids = (node.accessibilityElements as? [NSObject]) ?? []
            if kids.isEmpty {
                let count = node.accessibilityElementCount()
                if count != NSNotFound, count > 0 { kids = (0..<count).compactMap { node.accessibilityElement(at: $0) as? NSObject } }
            }
            if let view = node as? UIView { kids += view.subviews.filter { !$0.isHidden && $0.alpha > 0.01 } }
            for kid in kids { walk(kid, depth + 1) }
        }
        for root in roots() { walk(root, 0) }
        return out
    }

    /// 从上往下找东西的起点：各窗口里弹出的页面（新任务这类 sheet，最上面那层在前），再是窗口本身
    @MainActor private static func roots() -> [UIView] {
        var out: [UIView] = []
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).filter { !$0.isHidden }
        for window in windows.reversed() {
            var top = window.rootViewController
            var stack: [UIViewController] = []
            while let next = top?.presentedViewController { stack.append(next); top = next }
            out += stack.reversed().compactMap(\.view)
            out.append(window)
        }
        return out
    }

    @MainActor private static func tap(_ label: String) {
        let nodes = accessibilityNodes()
        guard let hit = nodes.first(where: { $0.accessibilityLabel == label }) ?? nodes.first(where: { $0.accessibilityLabel?.hasPrefix(label) == true }) else {
            note("tap \(label)：没找到")
            return
        }
        var done = hit.accessibilityActivate()
        if !done, let control = hit as? UIControl {
            control.sendActions(for: .touchUpInside)
            done = true
        }
        // 系统菜单（Menu）里的项是列表单元格：照系统选中那一格的路子交给列表的代理
        var view = hit as? UIView
        while !done, let current = view {
            if let cell = current as? UICollectionViewCell, let list = cell.superview(of: UICollectionView.self), let index = list.indexPath(for: cell) {
                if list.delegate?.collectionView?(list, shouldSelectItemAt: index) != false {
                    list.selectItem(at: index, animated: false, scrollPosition: [])
                    list.delegate?.collectionView?(list, didSelectItemAt: index)
                    done = true
                }
            }
            view = current.superview
        }
        var chain: [String] = []
        var up = hit as? UIView
        while let current = up, chain.count < 12 { chain.append(String(describing: type(of: current)) + (current.gestureRecognizers?.isEmpty == false ? "[手势 \(current.gestureRecognizers!.map { String(describing: type(of: $0)) }.joined(separator: ","))]" : "")); up = current.superview }
        note("tap \(label)：\(done ? "已点" : "找到了但点不了")（\(type(of: hit))，\(hit.accessibilityLabel ?? "")）" + (done ? "" : " 上层：" + chain.joined(separator: " < ")))
    }

    /// 导航类的命令转给 MainView（object 是整行命令）
    static let command = Notification.Name("TARSDebugRemoteCommand")
    @MainActor private static var listening = false
    private static var caches: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0] }

    /// 窗口里的滚动区（从上到下、从左到右）
    @MainActor private static func scrollViews(in window: UIWindow) -> [UIScrollView] {
        var found: [UIScrollView] = []
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView, !(scroll is UITextView), scroll.bounds.height > 100, !scroll.isHidden { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(window)
        return found
    }

    /// 排查用的一行记录：追加到 Library/Caches/remote-notes.txt（带时间），真机用 devicectl device copy from 取回
    static func note(_ text: String) {
        let url = caches.appendingPathComponent("remote-notes.txt")
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(text)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @MainActor static func listen() {
        guard !listening else { return }
        listening = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for action in actions {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                guard let name = name?.rawValue as String? else { return }
                let action = String(name.dropFirst("tars.demo.".count))
                Task { @MainActor in DebugRemote.run(action) }
            }, "tars.demo.\(action)" as CFString, nil, .deliverImmediately)
        }
    }

    @MainActor private static func run(_ action: String) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.compactMap(\.keyWindow).first else { return }
        func splitController(_ controller: UIViewController?) -> UISplitViewController? {
            guard let controller else { return nil }
            if let split = controller as? UISplitViewController { return split }
            return controller.children.lazy.compactMap { splitController($0) }.first
        }
        switch action {
        case "sidebar.hide": splitController(window.rootViewController)?.hide(.primary)
        case "sidebar.show": splitController(window.rootViewController)?.show(.primary)
        case "rotate.landscape", "rotate.portrait":
            // 普通 iPhone 走首页旋转按钮同一条路（只竖屏的 App 不放开方向转不过去）
            if Rotation.shared.available {
                Rotation.shared.set(action == "rotate.landscape")
            } else {
                window.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: action == "rotate.landscape" ? .landscapeRight : .portrait))
            }
        case "dump":
            let insets = window.safeAreaInsets
            var lines = ["window \(Int(window.bounds.width))x\(Int(window.bounds.height)) safe=\(Int(insets.top)),\(Int(insets.left)),\(Int(insets.bottom)),\(Int(insets.right))"]
            for (index, scroll) in scrollViews(in: window).enumerated() {
                let frame = scroll.convert(scroll.bounds, to: window)
                lines.append("#\(index) \(type(of: scroll)) frame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
                             + " content=\(Int(scroll.contentSize.width))x\(Int(scroll.contentSize.height))"
                             + " offset=\(Int(scroll.contentOffset.x)),\(Int(scroll.contentOffset.y))"
                             + " inset=\(Int(scroll.adjustedContentInset.top)),\(Int(scroll.adjustedContentInset.bottom))"
                             // 左右也记：横着时刘海那侧的安全区有没有被滚动区再让一次
                             + " insetLR=\(Int(scroll.adjustedContentInset.left)),\(Int(scroll.adjustedContentInset.right))"
                             + " safeLR=\(Int(scroll.safeAreaInsets.left)),\(Int(scroll.safeAreaInsets.right))"
                             + " firstChildX=\(Int(scroll.subviews.first.map { $0.convert($0.bounds, to: window).minX } ?? -1))")
            }
            let path = ProcessInfo.processInfo.environment["TARS_DEMO_DUMP"] ?? caches.appendingPathComponent("remote-dump.txt").path
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        case "cmd":
            let path = ProcessInfo.processInfo.environment["TARS_DEMO_CMD"] ?? caches.appendingPathComponent("remote-cmd.txt").path
            guard let line = (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else { return }
            let parts = line.split(separator: " ").map(String.init)
            if parts.first == "focus" {
                func field(_ view: UIView) -> UIView? {
                    if let text = view as? UITextView, text.isEditable { return text }
                    if view is UITextField { return view }
                    return view.subviews.lazy.compactMap(field).first
                }
                field(window)?.becomeFirstResponder()
            } else if parts.first == "route", parts.count >= 2, parts[1].first?.isNumber == true || parts[1].contains(":") {
                // route 后面跟地址才是这条；route usage 之类的页面名转给 MainView
                // 每个地址走哪张网卡（免费版不经 VPN 隧道连局域网的判断，见 LocalRoute），写进 remote-notes.txt
                note("route " + LocalRoute.explain(Array(parts.dropFirst())))
            } else if parts.first == "trhost" {
                // trhost [local] <英文>：直接交给连着的电脑翻，看结果（不受当前翻译服务设置影响）
                let local = parts.count > 1 && parts[1] == "local"
                let text = parts.dropFirst(local ? 2 : 1).joined(separator: " ")
                Task {
                    guard let host = Translator.shared.hostTranslate else { note("trhost：电脑没有翻译功能"); return }
                    let t0 = Date()
                    do { note("trhost\(local ? " local" : "")：\(try await host(text, "auto", "zh-Hans", local))（\(String(format: "%.2f", Date().timeIntervalSince(t0))) 秒）") }
                    catch { note("trhost 失败：\((error as? TranslateError)?.message ?? "\(error)")") }
                }
            } else if parts.first == "trprobe" {
                Task { await Translator.shared.probeApple() }
            } else if parts.first == "translated" {
                // 每条翻译的状态、试过哪些服务、为什么换下一个 / 失败，加上当前设置和系统翻译语言包状态
                let t = Translator.shared
                note("translate 设置 \(t.source)→\(t.target) \(t.engine.rawValue) auto=\(t.auto)：\(t.debugStates)")
                #if canImport(Translation)
                if #available(iOS 18, *) {
                    Task {
                        let a = LanguageAvailability()
                        for (from, to) in [("en", "zh-Hans"), ("zh-Hans", "en")] {
                            let status = await a.status(from: Locale.Language(identifier: from), to: Locale.Language(identifier: to))
                            note("translate 语言包 \(from)→\(to)：\(status)")
                        }
                    }
                }
                #endif
            } else if parts.first == "free", parts.count == 2 {
                // 模拟免费版开 / 关（同设置里的开关；截图版没有这个开关）
                #if DEBUG
                Store.shared.simulateFree = parts[1] == "on"
                #endif
                note("free \(parts[1]) isPro=\(Store.shared.isPro)")
            } else if parts.first == "termfocus" {
                // 点一下终端（弹出键盘和辅助键条）
                func terminal(_ view: UIView) -> UIView? {
                    if String(describing: type(of: view)) == "TerminalView" { return view }
                    return view.subviews.lazy.compactMap(terminal).first
                }
                _ = terminal(window)?.becomeFirstResponder()
            } else if parts.first == "inbound", parts.count >= 2 {
                InboundFiles.shared.receive(URL(fileURLWithPath: String(line.dropFirst("inbound ".count))))
            } else if parts.first == "link", parts.count == 2, let url = URL(string: parts[1]) {
                // 当作点了这条提示词链接（模拟器里 simctl openurl 会先弹「在 Kiteline 中打开？」，点不了）
                PromptLinks.shared.receive(url)
            } else if parts.first == "live", parts.count >= 2 {
                // 实时活动排版：live <电脑生成的 content-state JSON> = 本地开一个或更新现有的；live end = 结束全部
                // （模拟器收不到实时活动推送：App 没被允许通知时 simctl push 报 2003）
                Task { await Self.live(String(line.dropFirst("live ".count))) }
            } else if parts.first == "tap", parts.count >= 2 {
                withAccessibility { tap(String(line.dropFirst("tap ".count))) }
            } else if parts.first == "type", parts.count >= 2 {
                // 往第一个输入框里打字（筛选框、搜索框）：type 关键词
                withAccessibility {
                    func field(_ view: UIView) -> UITextField? {
                        if let text = view as? UITextField, !text.isHidden { return text }
                        return view.subviews.lazy.compactMap(field).first
                    }
                    guard let target = roots().lazy.compactMap(field).first else { note("type：没有输入框"); return }
                    target.becomeFirstResponder()
                    target.text = ""
                    target.insertText(String(line.dropFirst("type ".count)))
                    note("type 打进了 \(type(of: target))：\(target.text ?? "")")
                }
            } else if parts.first == "labels" {
                withAccessibility {
                    note("labels " + accessibilityNodes().compactMap(\.accessibilityLabel).map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | "))
                }
            } else if parts.first == "worldjs" {
                WorldBridge.current?.evaluate(String(line.dropFirst("worldjs".count)))
            } else if parts.first == "scroll", parts.count == 3, let index = Int(parts[1]), let delta = Double(parts[2]) {
                let list = scrollViews(in: window)
                guard list.indices.contains(index) else { return }
                let scroll = list[index]
                let lowest = -scroll.adjustedContentInset.top
                let highest = max(lowest, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
                let y = min(max(scroll.contentOffset.y + delta, lowest), highest)
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: true)
            } else {
                NotificationCenter.default.post(name: command, object: line)
            }
        default: break
        }
    }
}
#endif
