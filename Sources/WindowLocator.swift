import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// 找 Claude Code 会话所在的 VS Code 窗口。
///
/// VS Code 把当前打开的窗口记在 storage.json 的 windowsState 里（本机是 file://，
/// Remote-SSH 是 vscode-remote://ssh-remote+<主机>/路径）。会话的 cwd 是某个窗口工作区根目录
/// 或它的子目录，取最长的那个前缀就是会话所在窗口。
///
/// 远端主机的写法可能对不上：Kiteline 里叫 vm，VS Code 里填的是 10.168.1.10。
/// 所以两边都用 `ssh -G` 解析成最终的 hostname/port/user 再比。
enum WindowLocator {
    struct OpenFolder {
        var uri: String          // 原始 URI（带百分号编码）
        var authority: String?   // ssh-remote 的主机写法；本机为 nil
        var path: String
    }

    /// 编辑器各自的用户数据目录
    private static func storageURL(scheme: String) -> URL {
        EditorSettings.userDirectory(scheme: scheme).appendingPathComponent("globalStorage/storage.json")
    }

    static func openFolders(scheme: String) -> [OpenFolder] {
        guard let data = try? Data(contentsOf: storageURL(scheme: scheme)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = root["windowsState"] as? [String: Any] else { return [] }
        var raw: [String] = []
        for window in state["openedWindows"] as? [[String: Any]] ?? [] {
            if let folder = window["folder"] as? String { raw.append(folder) }
        }
        if let last = state["lastActiveWindow"] as? [String: Any], let folder = last["folder"] as? String {
            raw.append(folder)
        }
        var seen = Set<String>()
        return raw.compactMap { uri -> OpenFolder? in
            guard seen.insert(uri).inserted else { return nil }
            return parse(uri)
        }
    }

    static func parse(_ uri: String) -> OpenFolder? {
        if uri.hasPrefix("file://") {
            let path = String(uri.dropFirst("file://".count)).removingPercentEncoding ?? ""
            return OpenFolder(uri: uri, authority: nil, path: path)
        }
        let prefix = "vscode-remote://"
        guard uri.hasPrefix(prefix) else { return nil }
        let rest = String(uri.dropFirst(prefix.count))
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let authority = (String(rest[rest.startIndex..<slash]).removingPercentEncoding ?? "")
        guard authority.hasPrefix("ssh-remote+") else { return nil }
        let path = String(rest[slash...]).removingPercentEncoding ?? ""
        return OpenFolder(uri: uri, authority: String(authority.dropFirst("ssh-remote+".count)), path: path)
    }

    /// 会话所在窗口的深链；找不到返回 nil
    static func folderLink(for record: SessionRecord, source: SourceConfig?, scheme: String) -> URL? {
        guard let best = openFolder(cwd: record.snapshot.cwd, kind: record.kind, host: source?.sshHost, port: source?.sshPort,
                                    scheme: scheme) else { return nil }
        return link(best, scheme: scheme)
    }

    /// 工作区根目录包含 cwd 的已打开窗口（取最深的那个）
    static func openFolder(cwd: String, kind: SourceKind, host: String?, port: Int? = nil, scheme: String) -> OpenFolder? {
        guard !cwd.isEmpty else { return nil }
        let candidates = openFolders(scheme: scheme).filter { folder in
            guard cwd == folder.path || cwd.hasPrefix(folder.path.hasSuffix("/") ? folder.path : folder.path + "/") else { return false }
            return matches(folder, kind: kind, host: host, port: port)
        }
        return candidates.max(by: { $0.path.count < $1.path.count })
    }

    /// 窗口是不是这个来源的（本机窗口没有 authority；远端窗口比主机）
    static func matches(_ folder: OpenFolder, kind: SourceKind, host: String?, port: Int? = nil) -> Bool {
        switch kind {
        case .local: return folder.authority == nil
        case .ssh:
            guard let authority = folder.authority, let host = host else { return false }
            return sameHost(authority, host, port: port)
        }
    }

    /// vscode://file/<路径> 或 vscode://vscode-remote/ssh-remote+<主机>/<路径>：VS Code 会聚焦已打开的窗口
    static func link(_ folder: OpenFolder, scheme: String) -> URL? {
        if folder.uri.hasPrefix("file://") {
            return URL(string: "\(scheme)://file" + String(folder.uri.dropFirst("file://".count)))
        }
        return URL(string: "\(scheme)://vscode-remote/" + String(folder.uri.dropFirst("vscode-remote://".count)))
    }

    /// 还没打开的项目：用同样的深链让 VS Code 新开一个窗口。
    ///
    /// 不带参数的文件夹链接 VS Code 默认**复用最近活动的窗口**（window.openFoldersInNewWindow 为 default 时），
    /// 那个窗口里正在跑的 Claude 会话会随扩展宿主重启一起没了（10-22 实测）。VS Code 开着时一律带 `windowId=_blank`
    /// 强制新窗口（VS Code 处理协议链接时认这个参数，见 app.ts handleProtocolUrl）；没开着时不带：冷启动带它会多开一个空窗口
    static func newWindowLink(cwd: String, host: String?, port: Int? = nil, scheme: String, forceNew: Bool = true) -> URL? {
        let path = cwd.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cwd
        let query = forceNew ? "?windowId=_blank" : ""
        if let host = host {
            return URL(string: "\(scheme)://vscode-remote/ssh-remote+\(sshAuthority(host: host, port: port))\(path)\(query)")
        }
        return URL(string: "\(scheme)://file\(path)\(query)")
    }

    /// 打开 link（上面拼的 vscode://file/… 或 vscode://vscode-remote/…）指的项目窗口，completion 在窗口切过去之后回到主线程调。
    ///
    /// VS Code 收到这种链接先弹「外部应用程序想要在 VS Code 中打开…」（新装的都问，用户勾了「不再询问」才在设置里记成 false），
    /// 人不在电脑前就卡住。没关掉确认的不走链接，也不替用户关这个防护：
    /// 1. 窗口开着、标题只对得上一个：用辅助功能直接切过去（最快，不起新进程）；
    /// 2. 否则把同样的地址当启动参数交给 VS Code：经 LaunchServices 另起一个 VS Code 进程，它把参数转交给开着的那个就退出
    ///    （约 1.5 秒，其间程序坞里会多一个 VS Code 图标；VS Code 没开着时它自己就是主进程），这条路不弹确认。
    ///    不用 bin/code：它会设 VSCODE_CLI，新窗口就沿用调用方（Kiteline）那套精简的环境变量，不再读登录 shell 的 PATH
    static func open(_ link: URL, completion: (() -> Void)? = nil) {
        let finish = { DispatchQueue.main.async { completion?() } }
        let scheme = link.scheme ?? "vscode"
        guard let target = launchTarget(for: link),
              EditorSettings.promptsForFolderLinks(remote: target.remote, scheme: scheme),
              let bundleId = Delivery.Editor.known.first(where: { $0.scheme == scheme })?.bundleId,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            NSWorkspace.shared.open(link)
            finish()
            return
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
        if let running, !target.newWindow, raise(folder: target.folder, remote: target.remote, in: running) {
            finish()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // VS Code 有史以来第一次启动时先弹「Welcome to VS Code」登录引导，挡住一切：Kiteline 打开的跳过它（新窗口也不开欢迎页）
        configuration.arguments = target.arguments + ["--skip-welcome"]
        configuration.createsNewApplicationInstance = running != nil
        configuration.activates = running == nil   // 转交的进程不用激活：开着的 VS Code 收到参数会自己切到前台
        configuration.addsToRecentItems = false
        Log.write("用启动参数打开 VS Code 窗口：\(target.arguments.joined(separator: " ").removingPercentEncoding ?? "")")
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
            guard let app, error == nil else {
                Log.write("用启动参数打开 VS Code 窗口失败（\(error?.localizedDescription ?? "未知原因")），改用链接")
                DispatchQueue.main.async { NSWorkspace.shared.open(link); completion?() }
                return
            }
            guard running != nil else { finish(); return }
            // 等转交的进程退出（VS Code 处理完、窗口已切过去）；最多等 10 秒
            let pid = app.processIdentifier
            DispatchQueue.global(qos: .userInitiated).async {
                let deadline = Date().addingTimeInterval(10)
                while kill(pid, 0) == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                finish()
            }
        }
    }

    struct LaunchTarget {
        var arguments: [String]
        var remote: Bool
        var newWindow: Bool
        /// 工作区根目录名（窗口标题里显示的项目名）
        var folder: String
    }

    /// 链接换成 VS Code 启动参数：--folder-uri 地址，链接带 windowId=_blank 的加 --new-window
    static func launchTarget(for link: URL) -> LaunchTarget? {
        guard let components = URLComponents(url: link, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.percentEncodedPath
        let uri: String
        switch components.host {
        case "file": uri = "file://" + path
        case "vscode-remote": uri = "vscode-remote://" + path.dropFirst()
        default: return nil
        }
        let newWindow = components.queryItems?.contains { $0.name == "windowId" && $0.value == "_blank" } ?? false
        let folder = (components.path as NSString).lastPathComponent
        return LaunchTarget(arguments: (newWindow ? ["--new-window"] : []) + ["--folder-uri", uri],
                            remote: components.host == "vscode-remote", newWindow: newWindow, folder: folder)
    }

    /// 有辅助功能权限、标题对得上的窗口正好一个：把它切到前台（同名项目开了几个窗口时认不准，交给启动参数）
    private static func raise(folder: String, remote: Bool, in app: NSRunningApplication) -> Bool {
        guard AXIsProcessTrusted(), !folder.isEmpty, folder != "/" else { return false }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        let matching = windows.filter { window in
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            return Delivery.windowTitle(title as? String ?? "", matches: folder, remote: remote)
        }
        guard matching.count == 1, let window = matching.first else { return false }
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        Log.write("已切到项目「\(folder)」的 VS Code 窗口")
        return true
    }

    /// 远端窗口地址里的主机写法，照 Remote-SSH 自己的规则（HostInfo.toAuthorityString）：带用户名、端口、大写字母
    /// （VS Code 会把地址里的主机名转成小写）或 / \ + 的，写成 {"hostName","user","port"} 的 JSON 再转十六进制，其余原样。
    /// 端口只在 Kiteline 里填了、ssh 配置里没有时也能带过去；别名在 ssh 配置里有 HostName 的，Remote-SSH 照配置连
    static func sshAuthority(host: String, port: Int?) -> String {
        var user: String?
        var hostName = host
        if let at = host.lastIndex(of: "@") {
            user = String(host[..<at])
            hostName = String(host[host.index(after: at)...])
        }
        if user?.isEmpty == true { user = nil }
        guard user != nil || port != nil || hostName.lowercased() != hostName || hostName.contains(where: { "/\\+".contains($0) })
        else { return hostName }
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        // 字段顺序同 JSON.stringify：hostName、user、port
        var json = "{\"hostName\":\(quoted(hostName))"
        if let user { json += ",\"user\":\(quoted(user))" }
        if let port { json += ",\"port\":\(port)" }
        json += "}"
        return Data(json.utf8).map { String(format: "%02x", $0) }.joined()
    }

    /// 反过来：VS Code 窗口地址里的主机写法拆成 ssh 认的「[用户@]主机」和端口（十六进制 JSON 先解开）
    static func decodeAuthority(_ authority: String) -> (host: String, port: Int?) {
        guard authority.count >= 2, authority.count % 2 == 0, authority.allSatisfy(\.isHexDigit) else { return (authority, nil) }
        var bytes: [UInt8] = []
        var index = authority.startIndex
        while index < authority.endIndex {
            let next = authority.index(index, offsetBy: 2)
            guard let byte = UInt8(authority[index..<next], radix: 16) else { return (authority, nil) }
            bytes.append(byte)
            index = next
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              let hostName = json["hostName"] as? String, !hostName.isEmpty else { return (authority, nil) }
        let user = (json["user"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return ((user.map { "\($0)@" } ?? "") + hostName, (json["port"] as? NSNumber)?.intValue)
    }

    // MARK: - 主机比较

    private static var resolved: [String: String] = [:]
    private static let lock = NSLock()

    /// authority 是 VS Code 窗口地址里的主机写法（可能是十六进制 JSON），host、port 是 Kiteline 来源里填的
    static func sameHost(_ authority: String, _ host: String, port: Int? = nil) -> Bool {
        let theirs = decodeAuthority(authority)
        if theirs.port == port, theirs.host.caseInsensitiveCompare(host) == .orderedSame { return true }
        return canonical(theirs.host, port: theirs.port) == canonical(host, port: port)
    }

    /// `ssh -G` 给出的最终连接目标（hostname + port + user），带缓存
    static func canonical(_ host: String, port: Int? = nil) -> String {
        let key = port.map { "\(host)#\($0)" } ?? host
        lock.lock()
        if let hit = resolved[key] { lock.unlock(); return hit }
        lock.unlock()
        var result = host.lowercased()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G"] + (port.map { ["-p", String($0)] } ?? []) + [host]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            var fields: [String: String] = [:]
            for line in String(data: data, encoding: .utf8)?.split(separator: "\n") ?? [] {
                let parts = line.split(separator: " ", maxSplits: 1)
                if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
            }
            if let hostname = fields["hostname"] {
                result = "\(fields["user"] ?? "")@\(hostname.lowercased()):\(fields["port"] ?? "22")"
            }
        }
        lock.lock()
        resolved[key] = result
        lock.unlock()
        return result
    }

    // MARK: - 窗口数量（不需要任何权限）

    static func windowCount(of app: NSRunningApplication) -> Int {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return 0 }
        return list.filter {
            ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier
                && ($0[kCGWindowLayer as String] as? Int) == 0
        }.count
    }
}
