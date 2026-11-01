import AppKit
import Foundation
import KitelineKit

/// 与 Claude Code 窗口相关的小动作：跳转、剪贴板、权限引导、提示。投递消息见 Delivery。
enum Actions {

    // MARK: - 跳回 VS Code 窗口

    /// 已打开的项目用 VS Code 自己记的窗口地址聚焦那个窗口；没打开的新开一个窗口（本机 file、远端 vscode-remote 地址，见 WindowLocator.open）。
    /// 都不需要额外权限，只是把 VS Code 拉到前台并切到对应项目。
    /// VS Code 在虚拟屏幕上时（VirtualScreen）：用户要看这个窗口，把它挪回原来的位置
    static func jumpToWorkspace(record: SessionRecord, config: AppConfig) {
        let cwd = record.snapshot.cwd
        let source = config.sources.first(where: { $0.id == record.sourceId })
        let editor = Delivery.Editor.running()
        let scheme = editor?.scheme ?? "vscode"
        // 优先聚焦已经打开的那个窗口（主机写法、工作区根目录都以 VS Code 自己记录的为准）
        if editor != nil, let link = WindowLocator.folderLink(for: record, source: source, scheme: scheme) {
            Log.write("跳转 VS Code（已打开的窗口）: \(link.absoluteString)")
            VirtualScreen.shared.willShowEditor()
            WindowLocator.open(link) { VirtualScreen.shared.bringBackFocusedWindow() }
            return
        }
        // 没打开：以前本机会话用 file:// 打开，实际是在访达里打开了文件夹；远端链接不带参数又会替换掉最近用的 VS Code 窗口
        let host: String?
        switch record.kind {
        case .local:
            host = nil
        case .ssh:
            guard let sshHost = source?.sshHost, !cwd.isEmpty else {
                notifyUser(title: "无法跳转", body: "此远端来源未配置主机地址。")
                return
            }
            host = sshHost
        }
        let path = cwd.isEmpty ? NSHomeDirectory() : cwd
        guard let url = WindowLocator.newWindowLink(cwd: path, host: host, port: source?.sshPort, scheme: scheme,
                                                    forceNew: editor != nil) else {
            notifyUser(title: "无法跳转", body: "项目路径不合法：\(path)")
            return
        }
        Log.write("跳转 VS Code（新开窗口）: \(url.absoluteString)")
        // 远端项目要靠 Remote-SSH 扩展连过去：没装先装上（VS Code 没开着也能装）
        guard host != nil, let source else { WindowLocator.open(url); return }
        RemoteSSH.prepare(source: source, scheme: scheme) { result in
            switch result {
            case .success(let note):
                WindowLocator.open(url)
                // 密钥提醒每台主机只弹一次（每次跳转都弹太吵）
                if let note, warnedHosts.insert(source.id).inserted {
                    notifyUser(title: L("VS Code 可能无法连接此主机"), body: ServerLang.ui(note))
                }
            case .failure(let error):
                notifyUser(title: L("无法打开远端项目"), body: ServerLang.ui(error.description))
            }
        }
    }

    private static var warnedHosts = Set<String>()

    // MARK: - 权限

    /// 自检用：只记录将要执行的动作，不真的按键（无 GUI 权限时也能验证链路）
    private static var dryRun: Bool {
        ProcessInfo.processInfo.environment["CCPULSE_DRY_RUN"] == "1"
    }

    /// 无障碍权限检测；未授权时引导用户去开
    static func ensureAccessibilityForReply() -> Bool {
        if dryRun { return true }
        if AXIsProcessTrusted() { return true }
        let alert = NSAlert()
        let name = Delivery.accessibilityName
        alert.messageText = "需要「\(name)」权限才能代你回复"
        alert.informativeText = """
        Kiteline 需要定位会话所在的 VS Code 窗口，并代你粘贴消息、按下回车或选项键，因此必须获得「\(name)」权限。

        请打开「系统设置 → 隐私与安全性 → \(name)」，开启 Kiteline。
        仅「跳转到 VS Code」无需此权限。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
        return false
    }

    // MARK: - 剪贴板 / 提示

    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func notifyUser(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
