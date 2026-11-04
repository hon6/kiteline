import Foundation

/// 本机来源：直接以子进程方式运行打包在 App 内的 watcher，读本机 ~/.claude。
///
/// 为什么不复用 SSH 那条路（ssh localhost）：本机不需要握手、不需要 sshd、
/// 也不该因为 ssh 配置问题而监听不到本机的 Claude Code。
final class LocalSource: SourceConnection {
    weak var delegate: SourceConnectionDelegate?

    let config: SourceConfig
    var id: String { config.id }
    private(set) var state: LinkState = .stopped

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var reader: WatcherLineReader?
    private var watchdog: DispatchSourceTimer?
    private var lastEventAt = Date()
    private var restartAttempt = 0
    private var stoppedByUser = false
    /// 进程是 reload() 换掉的：退出后马上再起，不算断线
    private var reloading = false
    private var stderrTail: [String] = []
    private let queue = DispatchQueue(label: "ccpulse.local")
    private let rpc = WatcherRPC()
    private(set) var hostHome: String? = NSHomeDirectory()
    let hostFeatures: Set<String> = []   // 后台运行只给远端项目用

    init(config: SourceConfig) {
        self.config = config
    }

    func start() {
        stoppedByUser = false
        restartAttempt = 0
        launch()
    }

    func stop() {
        stoppedByUser = true
        reloading = false
        rpc.attach(nil)
        rpc.release(failing: "watcher 通道已断开")
        try? stdinPipe?.fileHandleForWriting.close()
        watchdog?.cancel()
        watchdog = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let process = process, process.isRunning {
            process.terminate()   // watcher 只读文件，TERM 即可；App 退出时也会走到这里
        }
        process = nil
        update(state: .stopped)
    }

    func reload() {
        // 没在跑的（等着重连、已停）不用管：下次起进程自然按新开关
        guard !stoppedByUser, process?.isRunning == true else { return }
        reloading = true
        if state.isLive {
            rpc.hold(for: LocalSource.reloadGrace) { [weak self] in
                // 新进程这么久还没就绪：照常算连接中
                guard let self = self, !self.stoppedByUser, self.state.isLive else { return }
                self.update(state: .connecting)
            }
        }
        rpc.drain(until: Date().addingTimeInterval(5)) { [weak self] in
            guard let self = self, self.reloading, let process = self.process, process.isRunning else { return }
            process.terminate()
        }
    }

    /// 换 watcher 进程（reload）：这么久内新进程就绪就不算断线
    static let reloadGrace: TimeInterval = 30

    // MARK: - 进程

    private func launch() {
        guard !stoppedByUser else { return }
        guard let scriptURL = resolveScript() else {
            update(state: .failed(reason: "App 内缺少 ccpulse-watch.py"))
            return
        }
        if !rpc.isHolding { update(state: .connecting) }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let (executable, arguments) = LocalSource.pythonCommand(config.remotePython)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments + [scriptURL.path]

        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "en_US.UTF-8"
        environment.merge(AgentSkill.watcherEnvironment) { _, new in new }
        if UserDefaults.standard.bool(forKey: "watcherDebug") {
            environment["CCPULSE_DEBUG"] = "1"
        }
        process.environment = environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // stdin 是请求通道（拉历史、取图片、落地手机图片）
        process.standardInput = stdinPipe

        let reader = WatcherLineReader(
            onEvent: { [weak self] event in self?.handle(event) },
            onGarbage: { [weak self] raw in
                guard let self = self else { return }
                self.delegate?.source(self, didLog: "忽略无法解析的行：\(raw)")
            }
        )
        self.reader = reader

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            reader.feed(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self = self else { return }
            if UserDefaults.standard.bool(forKey: "watcherDebug"),
               let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    Log.write("[本机 watcher stderr] \(line)")
                }
            }
            // watcher 的日志也留一小段尾巴，异常退出时能说清原因
            if let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n") where !line.isEmpty {
                    self.stderrTail.append(String(line))
                }
                if self.stderrTail.count > 12 { self.stderrTail.removeFirst(self.stderrTail.count - 12) }
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
                    self.delegate?.source(self, didLog: "本机 watcher 换进程载入插件变化")
                    self.launch()
                    return
                }
                let reason = self.stderrTail.last ?? "watcher 退出码 \(proc.terminationStatus)"
                self.delegate?.source(self, didLog: "本机 watcher 退出：\(reason)")
                self.scheduleRestart(reason: reason)
            }
        }

        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.lastEventAt = Date()
        self.stderrTail.removeAll()

        do {
            try process.run()
            rpc.attach(stdinPipe.fileHandleForWriting)
            delegate?.source(self, didLog: "本机 watcher 已启动（pid \(process.processIdentifier)）")
            startWatchdog()
        } catch {
            delegate?.source(self, didLog: "本机 watcher 启动失败：\(error.localizedDescription)")
            scheduleRestart(reason: error.localizedDescription)
        }
    }

    private func scheduleRestart(reason: String) {
        guard !stoppedByUser else { return }
        rpc.release(failing: reason)
        restartAttempt += 1
        let delay = min(30.0, pow(2.0, Double(min(restartAttempt, 5))))
        update(state: .failed(reason: reason))
        delegate?.source(self, didLog: "\(Int(delay)) 秒后重启本机 watcher（第 \(restartAttempt) 次）")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.launch()
        }
    }

    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self = self, let process = self.process, process.isRunning else { return }
            if Date().timeIntervalSince(self.lastEventAt) > 45 {
                self.delegate?.source(self, didLog: "超过 45 秒没有心跳，重启本机 watcher")
                process.terminate()
            }
        }
        timer.resume()
        watchdog = timer
    }

    func request(_ payload: [String: Any], timeout: TimeInterval,
                 completion: @escaping (Result<[String: Any], RemoteError>) -> Void) {
        rpc.send(payload, timeout: timeout, completion: completion)
    }

    private func handle(_ event: WatcherEvent) {
        lastEventAt = Date()
        restartAttempt = 0
        if rpc.consume(event) { return }
        if event.kind == "hello" {
            if let home = event.raw["home"] as? String { hostHome = home }
            rpc.release()   // 换进程期间排着的请求发给新进程
            update(state: .live(host: event.host ?? "本机", watcher: event.watcherVersion, sessionCount: 0))
            delegate?.source(self, didLog: "本机 watcher v\(event.watcherVersion ?? "?") 就绪")
        }
        if case .live(let host, let watcher, let count) = state, event.kind == "snapshots",
           count != event.sessions.count {
            update(state: .live(host: host, watcher: watcher, sessionCount: event.sessions.count))
        }
        delegate?.source(self, didReceive: event)
    }

    private func update(state newState: LinkState) {
        DispatchQueue.main.async {
            self.state = newState
            self.delegate?.source(self, didChange: newState)
        }
    }

    // MARK: - 脚本

    /// 选 Python：默认的 python3 优先直接用命令行工具里的那份。
    /// /usr/bin/python3 只是个转发壳，装了 Xcode 但还没同意许可协议时它会直接报错退出
    /// （实测：装完 Xcode、没跑 sudo xcodebuild -license 的机器上本机 watcher 起不来）。
    static func pythonCommand(_ configured: String) -> (String, [String]) {
        let cltPython = "/Library/Developer/CommandLineTools/usr/bin/python3"
        if configured == "python3", FileManager.default.isExecutableFile(atPath: cltPython) {
            return (cltPython, [])
        }
        if configured.hasPrefix("/") { return (configured, []) }
        return ("/usr/bin/env", [configured])
    }

    /// watcher 释放到 ~/.ccpulse/ccpulse-watch.py（与远端同一个位置）：
    /// 智能体要在 Bash 里调用它的 send-image 子命令，路径必须固定好记。
    private var installedScriptURL: URL {
        URL(fileURLWithPath: (config.remoteWatcherPath as NSString).expandingTildeInPath)
    }

    /// 确保本机有一份与 App 版本一致的 watcher，并返回它的路径
    private func resolveScript() -> URL? {
        guard let bundled = Bundle.main.url(forResource: "ccpulse-watch", withExtension: "py"),
              let bundledText = try? String(contentsOf: bundled, encoding: .utf8) else {
            return nil
        }
        let bundledVersion = AppVersion.watcherScriptVersion
        let target = installedScriptURL

        // 按内容比，不只比版本号：开发中改了脚本、版本号没变也要更新
        let installedText = try? String(contentsOf: target, encoding: .utf8)
        let needsWrite = installedText != bundledText

        if needsWrite {
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try bundledText.write(to: target, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
                Log.write("已释放本机 watcher 脚本 → \(target.path) (v\(bundledVersion))")
            } catch {
                Log.write("释放 watcher 脚本失败：\(error.localizedDescription)，退回直接读包内副本")
                return bundled
            }
        }
        return target
    }

    private static func scriptVersion(_ text: String?) -> String? {
        guard let text = text else { return nil }
        for line in text.split(separator: "\n") where line.contains("WATCHER_VERSION") {
            let parts = line.split(separator: "\"")
            if parts.count >= 2 { return String(parts[1]) }
        }
        return nil
    }
}
