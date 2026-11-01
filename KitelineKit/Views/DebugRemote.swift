#if (DEBUG || SNAPSHOT) && os(iOS)
import SwiftUI
import UIKit

/// 只在调试版、截图版里：从 Mac 上发 Darwin 通知遥控 App（点不了屏幕时测排版用）。
///   模拟器：xcrun simctl spawn <设备> notifyutil -p tars.demo.<动作>
///   真机：  xcrun devicectl device notification post --device <设备> --name tars.demo.<动作>
/// 动作：sidebar.hide / sidebar.show = 收起、拉出左栏（同点左上角的侧栏按钮）；rotate.landscape / rotate.portrait = 转屏（iPad 真机上系统不让 App 自己转）；
/// dump = 把窗口大小、各个滚动区的位置、大小、内容高、滚到哪写进 TARS_DEMO_DUMP（默认 App 的 Library/Caches/remote-dump.txt，
/// 真机用 devicectl device copy from --domain-type appDataContainer 取回来）；
/// cmd = 执行 Library/Caches/remote-cmd.txt 里的一行（真机用 devicectl device copy to 放进去）：
///   open <会话标题> / split <会话标题> / route today|usage|history|projects|inbox|todos|favorites|schedules|overview / back / home
///   dragpane <从第几块> <到第几块> <center|leading|trailing|top|bottom> [停几秒] = 照手势拖分屏的标题条；panes = 分屏现在的样子写进 remote-panes.txt
///   list [hide] = 横着的 iPhone 拉出 / 收起浮着的会话列表；settings = 横着的 iPhone 在浮着的列表里打开设置；
///   hint topLeft|topRight|portrait = 当作手里的手机转到那个方向（看转屏提示，见 RotationHint）
///   （这几样由 MainView 接，见 command）；scroll <第几个滚动区> <点数> = 把那个滚动区往下滚（负数往上）；focus = 点进输入框（弹出键盘）
///   world = 打开世界模式（会话列表接）；worldjs <脚本> = 在世界网页里执行一段脚本（如 World.openSession(key)）
///   inbound <路径> = 当作别的 App「用其他应用打开」发来这个文件（弹发送面板，见 InboundShare）；
///   inboundsend session|project <补充说明> = 在发送面板里填好说明、点「发送」（发给选中的会话 / 第一个项目新建会话）；
///   openfile / sharefile <会话 key> <路径> = 当作在消息里点了这个文件路径 / 长按「转发文件」（见 FileOpener；InboundShareHost 接）
///   route <IP>... = 每个地址走哪张网卡、算不算直连 / 走隧道（记进 remote-notes.txt）；free on|off = 模拟免费版开 / 关
enum DebugRemote {
    static let actions = ["sidebar.hide", "sidebar.show", "rotate.landscape", "rotate.portrait", "dump", "cmd"]
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
            } else if parts.first == "route" {
                // 每个地址走哪张网卡（免费版不经 VPN 隧道连局域网的判断，见 LocalRoute），写进 remote-notes.txt
                note("route " + LocalRoute.explain(Array(parts.dropFirst())))
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
