import Foundation
import KitelineKit
import ServiceManagement

/// 开机自动打开 Kiteline（登录项）。macOS 13 起用 SMAppService.mainApp；
/// macOS 12 没有 SMAppService，主 App 自己又不能用 SMLoginItemSetEnabled（那个要另带一个辅助 App），
/// 改成在 ~/Library/LaunchAgents 放一个 plist：登录时 launchd 用 open 打开 Kiteline（后台启动，不开主窗口）
enum KLLoginItem {
    static var enabled: Bool {
        if #available(macOS 13, *) { return SMAppService.mainApp.status == .enabled }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    static func register() throws {
        if #available(macOS 13, *) { try SMAppService.mainApp.register(); return }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-g", "-a", Bundle.main.bundlePath, "--args", "--background"],
            "RunAtLoad": true,
        ]
        try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: agentURL, options: .atomic)
    }

    static func unregister() throws {
        if #available(macOS 13, *) { try SMAppService.mainApp.unregister(); return }
        if FileManager.default.fileExists(atPath: agentURL.path) { try FileManager.default.removeItem(at: agentURL) }
    }

    /// 新标识用 kiteline 命名（旧的 com.mrhong.tars 是 bundle id，不动）
    private static let label = "com.kiteline.launch-at-login"
    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
}
