import Foundation

/// 命令行来源管理：不手改 JSON 也能增删监听来源。
///
/// 用法：
///   CCPulse sources list
///   CCPulse sources add local [--name 本机]
///   CCPulse sources add ssh <主机> [--name 别名] [--port 22] [--identity ~/.ssh/id_ed25519]
///   CCPulse sources remove <id>
///   CCPulse sources enable <id> / disable <id>
///
/// 注意：改完配置需要让正在运行的 App 重新加载（菜单栏右键 →「重新连接」）；
/// 如果 App 没在运行，下次启动自然会用新配置。
enum SourceCLI {
    static func run(arguments: [String]) -> Int32 {
        guard let subcommand = arguments.first else {
            printUsage()
            return 2
        }
        let rest = Array(arguments.dropFirst())

        switch subcommand {
        case "list", "ls":
            return listSources()
        case "add":
            return addSource(rest)
        case "remove", "rm":
            return removeSource(rest)
        case "enable", "disable":
            return toggleSource(rest, enable: subcommand == "enable")
        case "help", "--help", "-h":
            printUsage()
            return 0
        default:
            print("未知子命令：\(subcommand)")
            printUsage()
            return 2
        }
    }

    // MARK: - 子命令

    private static func listSources() -> Int32 {
        let config = AppConfig.load()
        if config.sources.isEmpty {
            print("当前没有配置任何来源。用 `sources add local` 或 `sources add ssh <主机>` 添加。")
            return 0
        }
        print("已配置 \(config.sources.count) 个来源：")
        for source in config.sources {
            let kind = source.kind == .local ? "本机" : "ssh"
            var line = "  \(source.enabled ? "●" : "○") \(source.id)  (\(kind))  \(source.displayName)"
            if let host = source.sshHost { line += "  → \(host)" }
            print(line)
            if !source.pathPrefixes.isEmpty {
                print("      只监听：\(source.pathPrefixes.joined(separator: "、"))")
            }
        }
        print("\n如需让运行中的 App 生效：菜单栏右键 →「重新连接」")
        return 0
    }

    private static func addSource(_ arguments: [String]) -> Int32 {
        guard let kindArgument = arguments.first else {
            print("用法：sources add local | sources add ssh <主机>")
            return 2
        }

        var config = AppConfig.load()
        var source: SourceConfig

        switch kindArgument {
        case "local":
            source = .local()
            if config.sources.contains(where: { $0.kind == .local }) {
                print("已存在本机来源（id=local）。")
                return 1
            }

        case "ssh":
            guard arguments.count >= 2 else {
                print("用法：sources add ssh <主机> [--name 别名] [--port 22] [--identity 路径]")
                return 2
            }
            let host = arguments[1]
            if config.sources.contains(where: { $0.sshHost == host }) {
                print("已存在指向 \(host) 的来源。")
                return 1
            }
            source = .ssh(host: host)
            let options = parseOptions(Array(arguments.dropFirst(2)))
            if let name = options["name"] { source.name = name }
            if let port = options["port"], let value = Int(port) { source.sshPort = value }
            if let identity = options["identity"] { source.sshIdentityFile = identity }

        default:
            print("无法识别的来源类型：\(kindArgument)（支持 local 或 ssh）")
            return 2
        }

        config.sources.append(source)
        config.save()
        print("已添加来源：\(source.id)（\(source.displayName)）")

        // 顺手用 ssh 探一下是否可达，给出即时反馈
        if source.kind == .ssh, let host = source.sshHost {
            probeSSH(host: host, port: source.sshPort, identity: source.sshIdentityFile)
        }
        print("如需让运行中的 App 生效：菜单栏右键 →「重新连接」")
        return 0
    }

    private static func removeSource(_ arguments: [String]) -> Int32 {
        guard let target = arguments.first else {
            print("用法：sources remove <id|主机|别名>（见 sources list）")
            return 2
        }
        var config = AppConfig.load()
        guard let index = findIndex(config, matching: target) else {
            print("未找到匹配「\(target)」的来源。可使用 sources list 查看。")
            return 1
        }
        let removed = config.sources.remove(at: index)
        config.save()
        print("已移除来源：\(removed.id)（\(removed.displayName)）")
        print("当前剩余 \(config.sources.count) 个来源。")
        print("如需让运行中的 App 生效：菜单栏右键 →「重新连接」")
        return 0
    }

    private static func toggleSource(_ arguments: [String], enable: Bool) -> Int32 {
        guard let target = arguments.first else {
            print("用法：sources \(enable ? "enable" : "disable") <id|主机|别名>")
            return 2
        }
        var config = AppConfig.load()
        guard let index = findIndex(config, matching: target) else {
            print("未找到匹配「\(target)」的来源。可使用 sources list 查看。")
            return 1
        }
        config.sources[index].enabled = enable
        config.save()
        print("已\(enable ? "启用" : "停用")来源：\(config.sources[index].id)")
        print("如需让运行中的 App 生效：菜单栏右键 →「重新连接」")
        return 0
    }

    /// 探一下 ssh 是否可达，以及远端有没有 watcher（首次会自动部署，这里只提示）
    private static func probeSSH(host: String, port: Int?, identity: String?) {
        var arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8"]
        if let port = port { arguments += ["-p", String(port)] }
        if let identity = identity, !identity.isEmpty {
            arguments += ["-i", (identity as NSString).expandingTildeInPath]
        }
        arguments += [host, "python3 -V && echo -- && (grep -m1 WATCHER_VERSION $HOME/.ccpulse/ccpulse-watch.py 2>/dev/null || echo '远端尚无 watcher（首次连接会自动部署）')"]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if process.terminationStatus == 0 {
                print("连通性检查：可达")
                for line in text.split(separator: "\n") where !line.isEmpty {
                    print("  \(line)")
                }
            } else {
                print("连通性检查：无法连接（\(text.split(separator: "\n").last ?? "未知原因")）")
                print("  请确认可免密 ssh 登录：ssh \(host) 'echo ok'")
            }
        } catch {
            print("连通性检查：无法执行 ssh（\(error.localizedDescription)）")
        }
    }

    /// 宽松查找：用户可能写 id、写主机名、或写别名。
    /// 早期只比 id，导致「remove 192.0.2.1」失败、用户又 add 一次变成重复条目。
    private static func findIndex(_ config: AppConfig, matching text: String) -> Int? {
        if let exact = config.sources.firstIndex(where: { $0.id == text }) { return exact }
        if let byPrefixed = config.sources.firstIndex(where: { $0.id == "ssh:\(text)" }) { return byPrefixed }
        if let byHost = config.sources.firstIndex(where: { $0.sshHost == text }) { return byHost }
        return config.sources.firstIndex(where: { $0.name == text })
    }

    private static func parseOptions(_ arguments: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            if key.hasPrefix("--"), index + 1 < arguments.count {
                result[String(key.dropFirst(2))] = arguments[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
        return result
    }

    private static func printUsage() {
        print("""
        Kiteline 命令行

          sources list                         列出已配置的来源
          sources add local [--name 本机]      添加本机来源
          sources add ssh <主机> [选项]         添加远端来源
              --name 别名       --port 端口       --identity 私钥路径
          sources remove <id|主机|别名>         移除来源（写主机名也行）
          sources enable <id|主机|别名>         启用来源
          sources disable <id|主机|别名>        停用来源

          sources help                        显示本帮助

        配置位置：\(AppConfig.fileURL.path)
        改完让运行中的 App 生效：菜单栏右键 →「重新连接」
        """)
    }
}
