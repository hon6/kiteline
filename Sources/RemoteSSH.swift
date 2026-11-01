import AppKit
import Foundation

/// 远端项目还没在 VS Code 里开着、要新开 Remote-SSH 窗口之前的准备（新任务、恢复会话、跳转到 VS Code 都走这里）：
/// 1. VS Code 没装 Remote-SSH 扩展：用 VS Code 自带的命令行装上（用户级、从扩展市场下载，VS Code 没开着也能装）；
/// 2. 密钥文件只在 Kiteline 里填了、ssh 配置里没有：VS Code 只读 ssh 配置，用不上这个密钥，提醒用户写进 ~/.ssh/config。
/// 端口不用管：窗口地址里的主机写法能带上端口（WindowLocator.sshAuthority）
enum RemoteSSH {
    static let extensionId = "ms-vscode-remote.remote-ssh"

    /// 只管 VS Code 正式版 / Insiders；VSCodium、Cursor 用的是各自的远程扩展
    private static func editor(scheme: String) -> (bundleId: String, dataFolder: String, cli: String)? {
        switch scheme {
        case "vscode": return ("com.microsoft.VSCode", ".vscode", "code")
        case "vscode-insiders": return ("com.microsoft.VSCodeInsiders", ".vscode-insiders", "code-insiders")
        default: return nil
        }
    }

    /// 装没装看 extensions.json（卸载后扩展目录要等 VS Code 重启才删）；不是 VS Code 返回 nil
    static func extensionInstalled(scheme: String) -> Bool? {
        guard let info = editor(scheme: scheme) else { return nil }
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("\(info.dataFolder)/extensions/extensions.json")
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
        return list.contains { (($0["identifier"] as? [String: Any])?["id"] as? String)?.lowercased() == extensionId }
    }

    /// VS Code 自带的命令行（App 包里的 bin/code）
    static func cli(scheme: String) -> URL? {
        guard let info = editor(scheme: scheme),
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: info.bundleId) else { return nil }
        let url = app.appendingPathComponent("Contents/Resources/app/bin/\(info.cli)")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// installing：要装扩展时先回一声（装要十几秒，手机的请求等不了）。
    /// completion 在主线程回：.success(要一并告诉用户的提醒，没有为 nil)、.failure(没法打开的原因)
    static func prepare(source: SourceConfig, scheme: String, installing: (() -> Void)? = nil,
                        completion: @escaping (Result<String?, RemoteError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let note = identityNote(source)
            func finish(_ result: Result<String?, RemoteError>) { DispatchQueue.main.async { completion(result) } }
            guard extensionInstalled(scheme: scheme) == false else { finish(.success(note)); return }
            guard let cli = cli(scheme: scheme) else {
                finish(.failure(RemoteError("VS Code 未安装 Remote-SSH 扩展，且找不到 VS Code 命令行，无法自动安装；请在 VS Code 的扩展中搜索「Remote - SSH」安装")))
                return
            }
            DispatchQueue.main.async { installing?() }
            Log.write("VS Code 未安装 Remote-SSH 扩展，正在安装")
            let (status, output) = run(cli, ["--install-extension", extensionId], timeout: 180)
            if extensionInstalled(scheme: scheme) == true {
                Log.write("已安装 Remote-SSH 扩展")
                finish(.success(note))
            } else {
                let reason = output.split(separator: "\n").last.map(String.init) ?? "退出码 \(status)"
                Log.write("Remote-SSH 扩展安装失败：\(output)")
                finish(.failure(RemoteError("VS Code 未安装 Remote-SSH 扩展，自动安装失败（\(reason)）；请在 VS Code 的扩展中搜索「Remote - SSH」安装")))
            }
        }
    }

    /// 密钥文件只填在 Kiteline 里时的提醒；没填密钥、或 ssh 配置里已经用这个密钥：nil
    static func identityNote(_ source: SourceConfig) -> String? {
        guard let identity = source.sshIdentityFile, !identity.isEmpty, let host = source.sshHost, !host.isEmpty else { return nil }
        let wanted = (identity as NSString).expandingTildeInPath
        let arguments = ["-G"] + (source.sshPort.map { ["-p", String($0)] } ?? []) + [host]
        let (_, output) = run(URL(fileURLWithPath: "/usr/bin/ssh"), arguments, timeout: 5)
        let configured = output.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("identityfile ") else { return nil }
            return (String(line.dropFirst("identityfile ".count)) as NSString).expandingTildeInPath
        }
        guard !configured.contains(wanted) else { return nil }
        return "该主机的密钥文件（\(identity)）只在 Kiteline 中设置，VS Code 无法使用，可能连接失败；请在 ~/.ssh/config 中为 \(host) 添加 IdentityFile"
    }

    // MARK: - 远端的 Claude Code 扩展

    enum RemoteExtension {
        case ready              // 远端本来就装着
        case installed          // 刚装上
        case failed(String)
        case unknown            // 看不出来（连不上、远端是 Windows 等）：照旧往下走
    }

    /// 远端窗口里 Claude Code 扩展跑在远端（工作区扩展）：远端没装时扩展链接会被 VS Code 悄悄丢掉（10-23 实测）。
    /// 经 ssh 用远端 VS Code 服务端自带的命令行装上，已经开着的窗口不用重载就能认出来（10-23 实测，首次约 40 秒）。
    /// 这台主机第一次用 VS Code 连、服务端还没装时，等新开的窗口把服务端装好再装扩展（解压到一半的 .staging 目录不算）。
    /// 网慢时下载扩展要好几分钟，最多等 15 分钟。
    /// installing：要装（或要等服务端）时先回一声；completion 在主线程回
    static func ensureRemoteExtension(source: SourceConfig, scheme: String, installing: (() -> Void)? = nil,
                                      completion: @escaping (RemoteExtension) -> Void) {
        // 只认 VS Code 正式版 / Insiders 的服务端目录
        guard let folder = ["vscode": ".vscode-server", "vscode-insiders": ".vscode-server-insiders"][scheme],
              let host = source.sshHost, !host.isEmpty else { completion(.unknown); return }
        // 装扩展要下载几十 MB，网慢时要好几分钟：放到远端后台装（ssh 断了也不影响），这边每几秒问一次结果
        let script = """
        d="$HOME/\(folder)"
        f="$d/extensions/extensions.json"
        log="$d/kiteline-claude-install.log"
        if grep -q '"anthropic.claude-code"' "$f" 2>/dev/null; then rm -f "$log.running" "$log.failed"; echo KL_HAS; exit 0; fi
        bin=
        for b in $(ls -td "$d"/cli/servers/Stable-*/server/bin/code-server "$d"/bin/*/bin/code-server 2>/dev/null); do
          case "$b" in *.staging*) continue ;; esac
          if [ -x "${b%/bin/code-server}/node" ]; then bin=$b; break; fi
        done
        if [ -z "$bin" ]; then echo KL_NOSERVER; exit 0; fi
        if [ "$1" = check ]; then echo KL_MISSING; exit 0; fi
        if [ -f "$log.failed" ]; then rm -f "$log.failed"; echo "KL_FAILED $(tail -n 1 "$log" 2>/dev/null)"; exit 0; fi
        if [ -z "$(find "$log.running" -mmin -20 2>/dev/null)" ]; then
          : > "$log.running"
          nohup sh -c '"$1" --install-extension anthropic.claude-code > "$2" 2>&1 || : > "$2.failed"; rm -f "$2.running"' sh "$bin" "$log" < /dev/null > /dev/null 2>&1 &
        fi
        echo KL_INSTALLING
        """
        var base = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=accept-new"]
        if let port = source.sshPort { base += ["-p", String(port)] }
        if let identity = source.sshIdentityFile, !identity.isEmpty { base += ["-i", (identity as NSString).expandingTildeInPath] }
        func remote(_ mode: String, timeout: TimeInterval) -> String {
            let (_, output) = run(URL(fileURLWithPath: "/usr/bin/ssh"), base + [host, "sh", "-s", mode], timeout: timeout, input: script)
            return output.split(separator: "\n").last(where: { $0.hasPrefix("KL_") }).map(String.init) ?? ""
        }
        DispatchQueue.global(qos: .userInitiated).async {
            func finish(_ state: RemoteExtension) { DispatchQueue.main.async { completion(state) } }
            let first = remote("check", timeout: 20)
            guard first == "KL_MISSING" || first == "KL_NOSERVER" else { finish(first == "KL_HAS" ? .ready : .unknown); return }
            DispatchQueue.main.async { installing?() }
            Log.write("远端 \(host) 未安装 Claude Code 扩展，\(first == "KL_NOSERVER" ? "等 VS Code 服务端装好后" : "现在")安装")
            let deadline = Date().addingTimeInterval(900)
            var misses = 0
            while true {
                let result = remote("install", timeout: 30)
                if result == "KL_HAS" {
                    Log.write("远端 \(host) 已安装 Claude Code 扩展")
                    finish(.installed); return
                }
                if result.hasPrefix("KL_FAILED") {
                    let reason = result.dropFirst("KL_FAILED".count).trimmingCharacters(in: .whitespaces)
                    Log.write("远端 \(host) 安装 Claude Code 扩展失败：\(reason)")
                    finish(.failed(reason.isEmpty ? "安装命令出错" : reason)); return
                }
                misses = result == "KL_NOSERVER" || result == "KL_INSTALLING" ? 0 : misses + 1
                if misses >= 5 { finish(.unknown); return }   // 连着几次连不上：看不出来，照旧往下走
                if Date() > deadline { finish(.failed("VS Code 服务端或扩展 15 分钟内未装好")); return }
                Thread.sleep(forTimeInterval: 4)
            }
        }
    }

    /// 跑一个命令，返回（退出码, 标准输出 + 标准错误）；超时就结束它。input：写进标准输入的内容
    private static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval, input: String? = nil) -> (Int32, String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return (-1, "无法运行 \(executable.lastPathComponent)") }
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        return (process.terminationStatus, String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}
