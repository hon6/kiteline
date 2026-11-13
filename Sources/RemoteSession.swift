import CryptoKit
import Foundation

/// 通过 SSH 长连接读取远端 watcher 的事件流。
///
/// 关键设计：
/// - 用 ControlMaster 复用同一条 SSH 连接，避免每次重连都做完整握手；
/// - 首次连接若远端缺少 watcher，自动把 App 内置的脚本 push 上去；
/// - 事件流带心跳，超时未收到任何事件即判定链路故障并指数退避重连。
final class RemoteSession: SourceConnection {
    weak var delegate: SourceConnectionDelegate?

    private(set) var state: LinkState = .stopped
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var reader: WatcherLineReader?
    private var stderrBuffer = Data()
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var watchdog: DispatchSourceTimer?
    private var lastEventAt = Date()
    let config: SourceConfig
    private var stoppedByUser = false
    /// 进程是 reload() 换掉的：退出后马上重连（重新同步插件），不算断线
    private var reloading = false
    private let queue = DispatchQueue(label: "ccpulse.transport")
    private let rpc = WatcherRPC()
    private(set) var hostHome: String?
    private(set) var hostFeatures: Set<String> = []

    /// 远端 watcher 脚本的本地权威副本（随 App 打包）。
    /// 最后直接按路径看文件：App 在安装包还没拷完时就被启动（11-14 两个会话同时装开发版），Bundle 记住了「没有这个文件」，
    /// 拷完了也一直找不到，本机和远端全连不上、要退出重开；直接看文件，拷完下次重试就好了
    static var bundledWatcherURL: URL? {
        if let url = Bundle.main.url(forResource: "ccpulse-watch", withExtension: "py")
            ?? Bundle.main.url(forResource: "ccpulse-watch", withExtension: "py", subdirectory: "Resources") {
            return url
        }
        let direct = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ccpulse-watch.py")
        return FileManager.default.fileExists(atPath: direct.path) ? direct : nil
    }

    var id: String { config.id }

    init(config: SourceConfig) {
        self.config = config
    }

    // MARK: - 生命周期

    func start() {
        stoppedByUser = false
        reconnectAttempt = 0
        connect()
    }

    func stop() {
        stoppedByUser = true
        reloading = false
        rpc.attach(nil)
        rpc.release(failing: "watcher 通道已断开")
        try? stdinPipe?.fileHandleForWriting.close()
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        watchdog?.cancel()
        watchdog = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let process = process, process.isRunning {
            process.terminate()
        }
        process = nil
        update(state: .stopped)
    }

    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.start()
        }
    }

    func reload() {
        // 没在跑的（等着重连、已停）不用管：下次连接时自然重新同步插件
        guard !stoppedByUser, process?.isRunning == true else { return }
        reloading = true
        if state.isLive {
            rpc.hold(for: LocalSource.reloadGrace) { [weak self] in
                guard let self = self, !self.stoppedByUser, self.state.isLive else { return }
                self.update(state: .connecting)
            }
        }
        rpc.drain(until: Date().addingTimeInterval(5)) { [weak self] in
            guard let self = self, self.reloading, let process = self.process, process.isRunning else { return }
            process.terminate()
        }
    }

    // MARK: - 连接

    private func connect() {
        guard !stoppedByUser else { return }
        if !rpc.isHolding { update(state: .connecting) }

        queue.async { [weak self] in
            guard let self = self else { return }
            self.ensureRemoteWatcher { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .failure(let error):
                    self.delegate?.source(self, didLog: "远端准备失败：\(error)")
                    self.scheduleReconnect(reason: LocalNetwork.explain(error.description))
                case .success:
                    self.launchStreamProcess()
                }
            }
        }
    }

    /// 远端是否已有 watcher；没有就上传随 App 打包的版本。
    /// 两者版本不一致时也以本地为准（保证协议匹配）。
    private func ensureRemoteWatcher(completion done: @escaping (Result<Void, RemoteError>) -> Void) {
        // watcher 就绪后把本机下载的插件也同步过去（远端不一定能上外网）；同步失败不影响连接，远端照用内置的
        let completion: (Result<Void, RemoteError>) -> Void = { result in
            guard case .success = result else { done(result); return }
            self.syncPlugins { done(result) }
        }
        loadBundledScript { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let (localScript, localVersion)):
                let remotePath = self.config.remoteWatcherPath
                // 版本号之外再比内容指纹（部署时写在旁边的 .sha 文件里）：脚本改了但版本号没变也会更新
                let check = "(v=$(grep -m1 -o 'WATCHER_VERSION = \"[^\"]*\"' \(self.remotePath(remotePath)) 2>/dev/null | sed 's/.*\"\\(.*\\)\"/\\1/'); echo \"VERSION=$v\"; echo \"SHA=$(cat \(self.remotePath(remotePath + ".sha")) 2>/dev/null)\")"
                self.runSSH(captureOutput: true, remoteCommand: check, timeout: 20) { probe in
                    switch probe {
                    case .failure(let error):
                        self.delegate?.source(self, didLog: "远端探测失败（\(error)），尝试部署 watcher")
                        self.uploadWatcher(script: localScript, completion: completion)
                    case .success(let output):
                        let remoteVersion = RemoteSession.parseVersion(from: output)
                        let remoteSHA = output.split(separator: "\n").first { $0.hasPrefix("SHA=") }?.dropFirst(4)
                        if remoteVersion == localVersion, localVersion != "unknown",
                           remoteSHA.map(String.init) == RemoteSession.fingerprint(localScript) {
                            self.delegate?.source(self, didLog: "远端 watcher v\(localVersion) 已就绪")
                            completion(.success(()))
                        } else {
                            self.delegate?.source(self, didLog: "远端 watcher 版本 \(remoteVersion ?? "缺失") → 更新到 v\(localVersion)")
                            self.uploadWatcher(script: localScript, completion: completion)
                        }
                    }
                }
            }
        }
    }

    private func loadBundledScript(completion: @escaping (Result<(String, String), RemoteError>) -> Void) {
        guard let localURL = RemoteSession.bundledWatcherURL,
              let localScript = try? String(contentsOf: localURL, encoding: .utf8) else {
            completion(.failure(RemoteError("App 内缺少 ccpulse-watch.py")))
            return
        }
        completion(.success((localScript, RemoteSession.scriptVersion(localScript) ?? "unknown")))
    }

    /// 本机的插件目录（PluginStore.pluginsDir）原样传到远端 ~/.ccpulse/plugins：指纹相同就不传
    private func syncPlugins(_ done: @escaping () -> Void) {
        let (archive, fingerprint) = PluginStore.bundle()
        runSSH(captureOutput: true, remoteCommand: PluginStore.remoteCheckCommand, timeout: 20) { probe in
            if case .success(let output) = probe, output.trimmingCharacters(in: .whitespacesAndNewlines) == fingerprint {
                done()
                return
            }
            let command = PluginStore.remoteUnpackCommand(python: self.config.remotePython, fingerprint: fingerprint)
            self.runSSH(captureOutput: true, stdinText: archive.base64EncodedString(), remoteCommand: command, timeout: 60) { result in
                if case .success(let output) = result, output.contains("PLUGINS_OK") {
                    self.delegate?.source(self, didLog: "已把插件同步到远端（\(fingerprint)）")
                } else {
                    self.delegate?.source(self, didLog: "同步插件到远端失败，远端照用内置插件")
                }
                done()
            }
        }
    }

    /// 右键菜单用：不比对版本，直接覆盖部署
    func deployWatcherForcibly() {
        loadBundledScript { result in
            switch result {
            case .failure(let error):
                self.delegate?.source(self, didLog: "强制部署失败：\(error)")
            case .success(let (script, version)):
                self.delegate?.source(self, didLog: "强制部署 watcher v\(version)…")
                self.uploadWatcher(script: script) { outcome in
                    if case .failure(let error) = outcome {
                        self.delegate?.source(self, didLog: "强制部署失败：\(error)")
                    }
                }
            }
        }
    }

    private func uploadWatcher(script: String, completion: @escaping (Result<Void, RemoteError>) -> Void) {
        let remotePath = config.remoteWatcherPath
        let quoted = self.remotePath(remotePath)
        let sha = self.remotePath(remotePath + ".sha")
        let command = "mkdir -p \"$(dirname \(quoted))\" && cat > \(quoted) && chmod +x \(quoted) && echo \(RemoteSession.fingerprint(script)) > \(sha) && echo UPLOAD_OK"
        runSSH(captureOutput: true, stdinText: script, remoteCommand: command, timeout: 40) { result in
            switch result {
            case .success(let output) where output.contains("UPLOAD_OK"):
                self.delegate?.source(self, didLog: "已部署 watcher 到 \(remotePath)")
                completion(.success(()))
            case .success(let output):
                completion(.failure(RemoteError("上传未确认：\(output.suffix(120))")))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func launchStreamProcess() {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshArguments + ["--", remoteShellCommand()]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // stdin 经 ssh 接到远端 watcher：拉历史、取图片、落地手机图片都走这里
        process.standardInput = stdinPipe

        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "en_US.UTF-8"
        process.environment = environment

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ingest(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self = self else { return }
            self.stderrBuffer.append(data)
            if self.stderrBuffer.count > 8192 {
                self.stderrBuffer.removeFirst(self.stderrBuffer.count - 8192)
            }
        }
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self = self else { return }
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                self.rpc.attach(nil)
                self.process = nil
                self.watchdog?.cancel()
                self.watchdog = nil
                guard !self.stoppedByUser else { return }
                if self.reloading {
                    self.reloading = false
                    self.delegate?.source(self, didLog: "换进程载入插件变化")
                    self.connect()
                    return
                }
                let err = String(data: self.stderrBuffer, encoding: .utf8)?
                    .split(separator: "\n").last.map(String.init) ?? ""
                let reason = err.isEmpty ? "ssh 退出码 \(proc.terminationStatus)" : err
                self.delegate?.source(self, didLog: "事件流中断：\(reason)")
                self.scheduleReconnect(reason: reason)
            }
        }

        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.reader = nil
        self.stderrBuffer.removeAll()
        self.lastEventAt = Date()

        do {
            try process.run()
            rpc.attach(stdinPipe.fileHandleForWriting)
            delegate?.source(self, didLog: "已启动事件流：\(process.processIdentifier)")
            startWatchdog()
        } catch {
            delegate?.source(self, didLog: "ssh 启动失败：\(error.localizedDescription)")
            scheduleReconnect(reason: error.localizedDescription)
        }
    }

    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self = self, let process = self.process, process.isRunning else { return }
            if Date().timeIntervalSince(self.lastEventAt) > 45 {
                self.delegate?.source(self, didLog: "超过 45 秒没有心跳，判定链路故障")
                process.terminate()
            }
        }
        timer.resume()
        watchdog = timer
    }

    private func scheduleReconnect(reason: String) {
        guard !stoppedByUser else { return }
        rpc.release(failing: reason)
        reconnectAttempt += 1
        let delay = min(30.0, pow(2.0, Double(min(reconnectAttempt, 5))))
        update(state: .failed(reason: reason))
        delegate?.source(self, didLog: "\(Int(delay)) 秒后重连（第 \(reconnectAttempt) 次）")
        let item = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - 事件解析

    private func ingest(_ data: Data) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.reader == nil {
                self.reader = WatcherLineReader(
                    onEvent: { [weak self] event in self?.handle(event) },
                    onGarbage: { [weak self] raw in
                        guard let self = self else { return }
                        self.delegate?.source(self, didLog: "忽略无法解析的行：\(raw)")
                    }
                )
            }
            self.reader?.feed(data)
        }
    }

    func request(_ payload: [String: Any], timeout: TimeInterval,
                 completion: @escaping (Result<[String: Any], RemoteError>) -> Void) {
        rpc.send(payload, timeout: timeout, completion: completion)
    }

    private func handle(_ event: WatcherEvent) {
        lastEventAt = Date()
        reconnectAttempt = 0
        if rpc.consume(event) { return }
        if event.kind == "hello" {
            if let home = event.raw["home"] as? String { hostHome = home }
            rpc.release()   // 换进程期间排着的请求发给新进程
            update(state: .live(host: event.host, watcher: event.watcherVersion, sessionCount: 0),
                   features: Set(event.raw["features"] as? [String] ?? []))
            delegate?.source(self, didLog: "远端 \(event.host ?? "?") watcher v\(event.watcherVersion ?? "?")")
        }
        if case .live(let host, let watcher, let count) = state, event.kind == "snapshots",
           count != event.sessions.count {
            update(state: .live(host: host, watcher: watcher, sessionCount: event.sessions.count))
        }
        delegate?.source(self, didReceive: event)
    }

    // MARK: - 一次性远端命令

    typealias CommandResult = Result<String, RemoteError>

    /// 在远端执行一条命令并取回 stdout。命令字符串均由本类内部构造，不接受外部拼接。
    func runCommand(_ remoteCommand: String, timeout: TimeInterval = 20, completion: @escaping (CommandResult) -> Void) {
        runSSH(captureOutput: true, remoteCommand: remoteCommand, timeout: timeout, completion: completion)
    }

    // MARK: - ssh 调用封装

    /// 排障用：完整 ssh 命令行
    var debugCommandLine: String {
        "ssh " + sshArguments.joined(separator: " ") + " -- " + remoteShellCommand()
    }

    private var sshArguments: [String] {
        var args = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=300",
            "-o", "ControlPath=\(controlPath)",
            "-o", "StrictHostKeyChecking=accept-new",
        ]
        if let port = config.sshPort { args += ["-p", String(port)] }
        if let identity = config.sshIdentityFile, !identity.isEmpty {
            args += ["-i", (identity as NSString).expandingTildeInPath]
        }
        args.append(config.sshHost ?? "")
        return args
    }

    private var controlPath: String {
        let dir = NSHomeDirectory() + "/.ssh/ccpulse"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let safeHost = (config.sshHost ?? "unknown").replacingOccurrences(of: "/", with: "_")
        return "\(dir)/\(safeHost).sock"
    }

    private func remoteShellCommand() -> String {
        let python = config.remotePython
        // 让远端 shell 展开 ~，并强制 UTF-8，保证中文目录名与结论文本不被破坏
        let extra = AgentSkill.watcherEnvironment.map { "\($0.key)=\($0.value) " }.joined()
        // 本机同步过去的插件放在远端单独的目录里，不碰远端自己装的 Kiteline 管的 ~/.ccpulse/plugins
        return "LANG=C.UTF-8 \(extra)\(PluginStore.remoteDirEnvironment) \(python) \(remotePath(config.remoteWatcherPath))"
    }

    private func runSSH(captureOutput: Bool,
                        stdinText: String? = nil,
                        remoteCommand: String,
                        timeout: TimeInterval,
                        completion: @escaping (CommandResult) -> Void) {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshArguments + ["--", remoteCommand]
        process.standardOutput = outPipe
        process.standardError = errPipe
        if stdinText != nil {
            process.standardInput = Pipe()
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "en_US.UTF-8"
        process.environment = environment

        var collected = Data()
        var collectedErr = Data()
        let lock = NSLock()
        let group = DispatchGroup()

        func drain(_ pipe: Pipe, isStdout: Bool) {
            group.enter()
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock()
                if isStdout { collected.append(data) } else { collectedErr.append(data) }
                lock.unlock()
                group.leave()
            }
        }

        drain(outPipe, isStdout: true)
        drain(errPipe, isStdout: false)

        do {
            try process.run()
        } catch {
            completion(.failure(RemoteError(error.localizedDescription)))
            return
        }

        if let text = stdinText, let handle = process.standardInput as? Pipe {
            // 用会抛 Swift 错误的 write(contentsOf:)：ssh 连不上主机会马上退出，旧的 write(_:) 往关掉的管道里写会抛
            // Objective-C 异常，接不住，整个 App 闪退（远端机器关机时 Kiteline 一启动就崩）
            try? handle.fileHandleForWriting.write(contentsOf: Data(text.utf8))
            try? handle.fileHandleForWriting.close()
        }

        let deadline = DispatchTime.now() + timeout
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: deadline, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        group.wait()

        let out = String(data: collected, encoding: .utf8) ?? ""
        let err = String(data: collectedErr, encoding: .utf8) ?? ""
        if process.terminationStatus == 0 {
            completion(.success(out))
        } else {
            let reason = err.split(separator: "\n").last.map(String.init) ?? "退出码 \(process.terminationStatus)"
            completion(.failure(RemoteError(reason)))
        }
    }

    // MARK: - 工具

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 远端路径的 shell 写法：~ 开头的部分必须交给远端 shell 展开。
    /// 单引号里的 ~ 不会展开——早期版本因此把 watcher 装进了远端家目录下一个名叫「~」的目录里。
    private func remotePath(_ path: String) -> String {
        if path == "~" { return "\"$HOME\"" }
        if path.hasPrefix("~/") { return "\"$HOME\"/" + shellQuote(String(path.dropFirst(2))) }
        return shellQuote(path)
    }

    /// features：这次连上时 watcher 报的能力表。和状态一起在主线程上写（读它的都在主线程；原来在读输出的线程上直接写）；
    /// 断开时清空，免得离线了还按上次连着时的能力判断
    private func update(state newState: LinkState, features: Set<String>? = nil) {
        DispatchQueue.main.async {
            if let features { self.hostFeatures = features } else if !newState.isLive { self.hostFeatures = [] }
            self.state = newState
            self.delegate?.source(self, didChange: newState)
        }
    }

    /// 脚本内容指纹（SHA-256 前 16 位十六进制）
    static func fingerprint(_ script: String) -> String {
        SHA256.hash(data: Data(script.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func scriptVersion(_ script: String) -> String? {
        for line in script.split(separator: "\n") {
            if line.contains("WATCHER_VERSION") {
                let parts = line.split(separator: "\"")
                if parts.count >= 2 { return String(parts[1]) }
            }
        }
        return nil
    }

    static func parseVersion(from output: String) -> String? {
        for line in output.split(separator: "\n") where line.hasPrefix("VERSION=") {
            let value = line.replacingOccurrences(of: "VERSION=", with: "").trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
