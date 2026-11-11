import Foundation
import Security
import KitelineKit

// MARK: - 来源配置

enum SourceKind: String, Codable {
    case local   // 本机上的 Claude Code（菜单栏 App 直接起 watcher 子进程）
    case ssh     // Remote-SSH 远端机器（通过 ssh 长连接读取事件流）
    case kiteline   // 互联的另一台 Kiteline 电脑上的一个来源（经那台电脑转过来，见 PeerComputers.swift）
}

/// 一个被监听的来源。可以是本机，也可以是一台远端主机。
struct SourceConfig: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var kind: SourceKind

    // ssh 专用
    var sshHost: String?
    var sshPort: Int?
    var sshIdentityFile: String?

    // 两处通用
    var remotePython: String = "python3"
    var remoteWatcherPath: String = "~/.ccpulse/ccpulse-watch.py"

    /// 只关心这些前缀的目录；空表示该来源全部监听
    var pathPrefixes: [String] = []
    var enabled: Bool = true
    /// 这台远端电脑上的新任务、恢复会话不开 VS Code，在那台电脑上后台运行 Claude Code（见 Hosted.swift）。
    /// 按设备开，默认关：用户检测过这台的出口、看过结果点确认才开
    var hostedOn: Bool = false

    // kiteline 专用：哪台电脑（PeerComputer.id）、那台电脑上的哪个来源（来源列表由 PeerComputers 按对方报的自动增删）
    var peerId: String?
    var peerSource: String?

    init(id: String, name: String, kind: SourceKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    /// 手写解码：缺失字段回落默认值（理由同 MobileConfig）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ConfigKey.self)
        let rawKind = ((try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil) ?? "local"
        kind = SourceKind(rawValue: rawKind) ?? .local
        sshHost = (try? c.decodeIfPresent(String.self, forKey: .sshHost)) ?? nil
        let fallbackId = kind == .local ? "local" : "ssh:\(sshHost ?? UUID().uuidString)"
        id = ((try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil) ?? fallbackId
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil)
            ?? (kind == .local ? "本机" : (sshHost ?? "远端"))
        sshPort = (try? c.decodeIfPresent(Int.self, forKey: .sshPort)) ?? nil
        sshIdentityFile = (try? c.decodeIfPresent(String.self, forKey: .sshIdentityFile)) ?? nil
        remotePython = ((try? c.decodeIfPresent(String.self, forKey: .remotePython)) ?? nil) ?? "python3"
        remoteWatcherPath = ((try? c.decodeIfPresent(String.self, forKey: .remoteWatcherPath)) ?? nil)
            ?? "~/.ccpulse/ccpulse-watch.py"
        pathPrefixes = ((try? c.decodeIfPresent([String].self, forKey: .pathPrefixes)) ?? nil) ?? []
        enabled = ((try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil) ?? true
        hostedOn = ((try? c.decodeIfPresent(Bool.self, forKey: .hostedOn)) ?? nil) ?? false
        peerId = (try? c.decodeIfPresent(String.self, forKey: .peerId)) ?? nil
        peerSource = (try? c.decodeIfPresent(String.self, forKey: .peerSource)) ?? nil
    }

    static func local() -> SourceConfig {
        SourceConfig(id: "local", name: "本机", kind: .local)
    }

    static func ssh(host: String, name: String? = nil) -> SourceConfig {
        var source = SourceConfig(id: "ssh:\(host)", name: name ?? host, kind: .ssh)
        source.sshHost = host
        return source
    }

    var displayName: String {
        switch kind {
        case .local: return name.isEmpty ? "本机" : name
        case .ssh: return name.isEmpty ? (sshHost ?? "远端") : name
        case .kiteline: return name.isEmpty ? PeerComputers.shared.defaultName(self) : name
        }
    }
}

// MARK: - 手机访问配置

/// 配置里出现过的所有键。用手写解码器的类型也复用它，避免键名写错。
enum ConfigKey: String, CodingKey {
    case sources, mobile
    case notifyOnNeedsAttention, notifyOnConclusion, playSound
    case conclusionCooldownSeconds, attentionCooldownSeconds, connectOnLaunch, jumpBackURI
    // 来源
    case id, name, kind, enabled, pathPrefixes, hostedOn
    case sshHost, sshPort, sshIdentityFile, remotePython, remoteWatcherPath, peerId, peerSource
    // 手机访问
    case port, bindAddress, token, publicURL, submitOnSend, installAgentSkill, installTestSkill, installTodoSkill, installStageSkill, installOpenCodePlugin
    case httpsEnabled, httpsPort, pushContact, voiceLocale, digestTime, quickReplies, dailyBudget
    case barkURL, barkMode, barkKey, barkIV, dailyCap, morningTime, remindWaiting, autoCloseIdle, hostedTipOff
    case quietStart, quietEnd, mutedSessions, pinnedSessions, markedSessions, myName, avatar, remoteEnabled, relayURL, watch, usageStats
    // 旧版扁平字段
    case watchedPathPrefixes
}

/// 手机端（网页 App）访问。Kiteline 在本机开一个 HTTP 服务，同时托管手机网页；
/// 手机用配对链接（带令牌）登录一次，之后凭 Cookie 访问。
/// 在外远程访问靠 Tailscale 这类组网工具，或用 `tailscale serve` 套一层 HTTPS。
struct MobileConfig: Codable, Equatable {
    var enabled: Bool = true
    var port: Int = 8765
    /// 0.0.0.0 = 局域网/Tailscale 都能连；只想本机自用就填 127.0.0.1
    var bindAddress: String = "0.0.0.0"
    /// 配对令牌：首次启动随机生成；在「手机访问」窗口里可以重置（旧手机随之失效）
    var token: String = ""
    /// 对外地址（可选），比如 tailscale serve 给的 https://mac.tailnet.ts.net ，会出现在配对二维码里
    var publicURL: String = ""
    /// 手机上点「发送」是否直接提交（否则只预填进输入框）
    var submitOnSend: Bool = true
    /// 自动给每台机器装一个 Claude Code 技能，让智能体知道怎么把图片发到手机
    var installAgentSkill: Bool = true
    /// 再装一个网页测试技能：网页做完后 Claude 用 Playwright 实测、每步截图，出图文测试报告发到手机
    var installTestSkill: Bool = true
    /// 待办与关键信息技能：agent 把要留到以后的事记进待办、把账号密码这类关键信息单独发来供收藏
    var installTodoSkill: Bool = true
    /// 任务阶段技能：agent 进入调研、开发、测试、汇报 / 发布时报一下，会话列表显示「2/4 开发中」（不装也按工具调用自动推断）
    var installStageSkill: Bool = true
    /// 每台机器上装了 OpenCode 的，自动给它装 Kiteline 插件（手机才看得到、操作得了 OpenCode 的会话）；关掉时 watcher 会删掉装过的
    var installOpenCodePlugin: Bool = true
    /// 同时开一个 HTTPS 端口（本机签发证书）：iOS 网页推送必须走 HTTPS
    var httpsEnabled: Bool = true
    /// 0 = 普通端口 + 1
    var httpsPort: Int = 0
    /// 推送服务要求的联系方式（mailto: 或 https:）
    var pushContact: String = "mailto:ccpulse@users.noreply.github.com"
    /// 「按住说话」的识别语言（zh-CN 普通话、zh-HK 粤语、en-US 英语…）
    var voiceLocale: String = "zh-CN"
    /// 每日日报推送时间（"HH:mm"，本地时间）；空 = 不推
    var digestTime: String = "21:30"
    /// 早安简报：早上推一份昨晚 18:00 以来的动态和正在等你的会话；空 = 不推
    var morningTime: String = "08:30"
    /// 等你确认太久（10 分钟、30 分钟）时再提醒一次
    var remindWaiting: Bool = true
    /// 24 小时没在 Kiteline 里打开过详情的会话自动关闭、进历史会话（标记、置顶的也关；见 IdleClose.swift）
    var autoCloseIdle: Bool = true
    /// 「支持后台运行 Claude Code」的提示（会话页、来源页）：勾了「不再提示」就不再显示（各端共用）。
    /// 开关本身按设备，见 SourceConfig.hostedOn（先前那版是这里一个默认开的 hostedRemote，那时的值不算数）
    var hostedTipOff: Bool = false
    /// 免打扰时段（"HH:mm"，可跨午夜）：这段时间「有结论了 / 发来图片 / 定时任务」不推到锁屏，「需要你确认」和花费提醒照推；空 = 不启用
    var quietStart: String = "23:00"
    var quietEnd: String = "08:00"
    /// 静音的会话（会话 key）：只在需要你确认时推，结论和图片都不推
    var mutedSessions: [String] = []
    /// 置顶的会话（会话 key）：手机和 Mac 的列表里排在最上面
    var pinnedSessions: [String] = []
    /// 标记的会话（会话 key，主题色星星）：各端所有列表的最上面，不受分组限制；关闭会话、会话结束时自动取消（10-27）
    var markedSessions: [String] = []
    /// 对话里「我」的名字；空 = 用这台 Mac 当前用户的全名
    var myName: String = ""
    /// 对话里「我」的头像：mac = Mac 账户头像（默认），system:<分类>/<名字> = 系统自带头像，custom = 自己选的图，text = 名字首字
    var avatar: String = "mac"
    /// 远程访问（点对点）：手机不在同一个 Wi-Fi 时也能连这台 Mac
    var remoteEnabled: Bool = true
    /// 远程访问的中继服务器；空 = Kiteline 自己的中继（builtinRelay）
    var relayURL: String = ""
    /// Apple Watch 上的选项（见 WatchSupport.swift）：手机 App 和 Mac 设置里改的是这一份
    var watch = WatchConfig()
    /// 发送使用统计（见 UsageStats.swift）：设备、会话的数字和类别，不含对话和代码
    var usageStats: Bool = true

    /// 现在是不是在免打扰时段里
    func inQuietHours(_ now: Date = Date()) -> Bool {
        guard let start = DailyReport.scheduledDate(quietStart, on: now), let end = DailyReport.scheduledDate(quietEnd, on: now),
              start != end else { return false }
        return start < end ? (now >= start && now < end) : (now >= start || now < end)
    }

    /// 这类提醒现在要不要推到锁屏（应用内横幅不受影响）
    func shouldPush(kind: String, key: String?) -> Bool {
        if kind == "attention" || kind == "budget" || kind == "test" { return true }
        if let key = key, mutedSessions.contains(key), ["conclusion", "image", "error", "stuck", "todo", "keyinfo", "goal"].contains(kind) { return false }
        if inQuietHours(), ["conclusion", "image", "schedule", "error", "stuck", "editor", "link", "todo", "keyinfo", "group", "goal"].contains(kind) { return false }
        return true
    }
    /// Bark 备用推送：Bark App 里的地址（https://api.day.app/<key>）；空 = 不用
    var barkURL: String = ""
    /// attention = 只推需要你确认的（和花费提醒），all = 全部，off = 关
    var barkMode: String = "attention"
    /// 可选：Bark App 里设置的加密密钥（16/24/32 字符）与 IV（16 字符）
    var barkKey: String = ""
    var barkIV: String = ""
    /// 每日花费提醒（美元）：今天花到 80% / 100% 时推送；0 = 不提醒
    var dailyBudget: Double = 0
    /// 每日花费硬上限（美元）：超了以后定时任务跳过、新任务 / 恢复会话 / 手机发消息先拦住（确认后仍可发）；0 = 不限
    var dailyCap: Double = 0
    /// 快捷短语：手机和 Mac 对话页输入框上方的一排按钮，点一下直接发给 Claude
    var quickReplies: [String] = MobileConfig.defaultQuickReplies

    /// 默认的常用语：新装、「恢复默认」时按这台电脑的界面语言给（存下来以后就是用户自己的内容，不跟着换）
    static var defaultQuickReplies: [String] {
        Lang.shared.isEnglish
            ? ["Continue", "Go with this plan", "Take a screenshot so I can check", "Run the tests and send me the results",
               "Summarize the changes", "Pause and wait until I'm back"]
            : ["继续", "按此方案执行", "截图查看效果", "运行测试并发送结果", "总结本次改动", "暂停，等我回来再继续"]
    }

    /// 去空、去重、限长：最多 24 条，每条最多 200 字
    static func cleanQuickReplies(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in items {
            let text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            guard !text.isEmpty, seen.insert(text).inserted else { continue }
            out.append(text)
            if out.count == 24 { break }
        }
        return out
    }

    var effectiveHTTPSPort: Int { httpsPort > 0 ? httpsPort : port + 1 }
    /// Kiteline 自己的中继（上海，relay/deploy.sh 部署），设置里没填自建中继时用它
    static let builtinRelay = "https://tars.betac.cn"
    var effectiveRelay: String { relayURL.isEmpty ? Self.builtinRelay : relayURL }

    init() {}

    /// 手写解码：任何一个字段缺失都回落默认值。
    /// 不能用合成解码器——它对「带默认值的属性」并不会在键缺失时用默认值，
    /// 而是直接抛 keyNotFound，导致整份配置解码失败、App 静默退回全默认（踩过一次）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ConfigKey.self)
        func text(_ key: ConfigKey, _ fallback: String) -> String {
            (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil ?? fallback
        }
        func flag(_ key: ConfigKey, _ fallback: Bool) -> Bool {
            (try? c.decodeIfPresent(Bool.self, forKey: key)) ?? nil ?? fallback
        }
        enabled = flag(.enabled, true)
        port = (try? c.decodeIfPresent(Int.self, forKey: .port)) ?? nil ?? 8765
        bindAddress = text(.bindAddress, "0.0.0.0")
        token = text(.token, "")
        publicURL = text(.publicURL, "")
        submitOnSend = flag(.submitOnSend, true)
        installAgentSkill = flag(.installAgentSkill, true)
        installTestSkill = flag(.installTestSkill, true)
        installTodoSkill = flag(.installTodoSkill, true)
        installStageSkill = flag(.installStageSkill, true)
        installOpenCodePlugin = flag(.installOpenCodePlugin, true)
        httpsEnabled = flag(.httpsEnabled, true)
        httpsPort = (try? c.decodeIfPresent(Int.self, forKey: .httpsPort)) ?? nil ?? 0
        pushContact = text(.pushContact, "mailto:ccpulse@users.noreply.github.com")
        voiceLocale = text(.voiceLocale, "zh-CN")
        digestTime = text(.digestTime, "21:30")
        morningTime = text(.morningTime, "08:30")
        remindWaiting = flag(.remindWaiting, true)
        autoCloseIdle = flag(.autoCloseIdle, true)
        hostedTipOff = flag(.hostedTipOff, false)
        quietStart = text(.quietStart, "23:00")
        quietEnd = text(.quietEnd, "08:00")
        mutedSessions = (try? c.decodeIfPresent([String].self, forKey: .mutedSessions)) ?? nil ?? []
        pinnedSessions = (try? c.decodeIfPresent([String].self, forKey: .pinnedSessions)) ?? nil ?? []
        markedSessions = (try? c.decodeIfPresent([String].self, forKey: .markedSessions)) ?? nil ?? []
        myName = text(.myName, "")
        avatar = text(.avatar, "mac")
        remoteEnabled = flag(.remoteEnabled, true)
        relayURL = text(.relayURL, "")
        watch = (try? c.decodeIfPresent(WatchConfig.self, forKey: .watch)) ?? nil ?? WatchConfig()
        usageStats = flag(.usageStats, true)
        quickReplies = (try? c.decodeIfPresent([String].self, forKey: .quickReplies)) ?? nil ?? MobileConfig.defaultQuickReplies
        dailyBudget = (try? c.decodeIfPresent(Double.self, forKey: .dailyBudget)) ?? nil ?? 0
        dailyCap = (try? c.decodeIfPresent(Double.self, forKey: .dailyCap)) ?? nil ?? 0
        barkURL = text(.barkURL, "")
        barkMode = text(.barkMode, "attention")
        barkKey = text(.barkKey, "")
        barkIV = text(.barkIV, "")
    }

    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 应用配置

/// 配置存放在 ~/Library/Application Support/TARS/config.json，
/// 首次启动自动生成，改完在菜单里点「重新连接」即可生效。
struct AppConfig: Codable {
    /// 被监听的来源列表。
    /// 默认只监听本机——不要内置任何远端主机名：那既是别人的机器地址，
    /// 也会让新用户一启动就去 SSH 一台不存在的机器（早期版本写死过 192.168.1.11）。
    var sources: [SourceConfig] = [.local()]

    /// 手机访问
    var mobile: MobileConfig = MobileConfig()

    /// 提醒策略
    var notifyOnNeedsAttention: Bool = true
    var notifyOnConclusion: Bool = true
    var playSound: Bool = true
    /// 同一会话两次提醒的最小间隔（秒）
    var conclusionCooldownSeconds: Double = 20
    var attentionCooldownSeconds: Double = 10
    var connectOnLaunch: Bool = true
    /// 最近一次打开的远端窗口 URI（用于「跳回项目」精确还原）
    var jumpBackURI: String? = nil

    // MARK: 兼容旧版扁平字段

    private enum LegacyKeys: String, CodingKey {
        case sshHost, sshPort, sshIdentityFile, remoteWatcherPath, remotePython, watchedPathPrefixes
    }

    private enum CodingKeys: String, CodingKey {
        case sources, mobile, notifyOnNeedsAttention, notifyOnConclusion, playSound
        case conclusionCooldownSeconds, attentionCooldownSeconds, connectOnLaunch, jumpBackURI
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sources = try container.decodeIfPresent([SourceConfig].self, forKey: .sources) ?? []
        mobile = try container.decodeIfPresent(MobileConfig.self, forKey: .mobile) ?? MobileConfig()
        notifyOnNeedsAttention = try container.decodeIfPresent(Bool.self, forKey: .notifyOnNeedsAttention) ?? true
        notifyOnConclusion = try container.decodeIfPresent(Bool.self, forKey: .notifyOnConclusion) ?? true
        playSound = try container.decodeIfPresent(Bool.self, forKey: .playSound) ?? true
        conclusionCooldownSeconds = try container.decodeIfPresent(Double.self, forKey: .conclusionCooldownSeconds) ?? 20
        attentionCooldownSeconds = try container.decodeIfPresent(Double.self, forKey: .attentionCooldownSeconds) ?? 10
        connectOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .connectOnLaunch) ?? true
        jumpBackURI = try container.decodeIfPresent(String.self, forKey: .jumpBackURI)

        // 注意区分「键不存在」与「显式空数组」：
        // 前者是老配置需要迁移，后者是用户明确表示不监听任何来源。
        let sourcesPresent = container.contains(.sources)
        if !sourcesPresent {
            // 老版本配置只有一台远端：迁移成「本机 + 那台远端」
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            var migrated: [SourceConfig] = [.local()]
            if let host = try legacy.decodeIfPresent(String.self, forKey: .sshHost), !host.isEmpty {
                var sshSource = SourceConfig.ssh(host: host)
                sshSource.sshPort = try legacy.decodeIfPresent(Int.self, forKey: .sshPort)
                sshSource.sshIdentityFile = try legacy.decodeIfPresent(String.self, forKey: .sshIdentityFile)
                sshSource.remoteWatcherPath = try legacy.decodeIfPresent(String.self, forKey: .remoteWatcherPath) ?? sshSource.remoteWatcherPath
                sshSource.remotePython = try legacy.decodeIfPresent(String.self, forKey: .remotePython) ?? sshSource.remotePython
                sshSource.pathPrefixes = try legacy.decodeIfPresent([String].self, forKey: .watchedPathPrefixes) ?? []
                migrated.append(sshSource)
            }
            sources = migrated
        } else {
            sources = sources.map { source in
                var copy = source
                if copy.remoteWatcherPath.isEmpty { copy.remoteWatcherPath = "~/.ccpulse/ccpulse-watch.py" }
                if copy.remotePython.isEmpty { copy.remotePython = "python3" }
                return copy
            }
        }
    }

    // MARK: 存取

    static let directoryName = "TARS"
    static let fileName = "config.json"

    /// 测试实例：另指定了配置目录，或者不真发送（自测、截图用）
    static var isolated: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["CCPULSE_DRY_RUN"] == "1" || !(env["CCPULSE_CONFIG_DIR"] ?? "").isEmpty
    }

    /// 偏好设置：测试实例用自己单独的一份。和正式 App 是同一个 bundle id，共用 UserDefaults 会互相写乱
    /// （测试实例藏起菜单栏图标，正式 App 下次启动图标也没了；测试的假会话混进正式 App 的已知会话）
    static var defaults: UserDefaults {
        isolated ? (UserDefaults(suiteName: "com.mrhong.tars.test-instance") ?? .standard) : .standard
    }

    static var directoryURL: URL {
        // 允许用环境变量指定配置目录：测试隔离、或一份机器多套配置之间切换
        if let override = ProcessInfo.processInfo.environment["CCPULSE_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    static var fileURL: URL { directoryURL.appendingPathComponent(fileName) }

    /// 改名前（CC Pulse）的数据目录：第一次以 Kiteline 启动时整份拷过来（配对令牌、证书、推送订阅都沿用，手机不用重配）
    static let legacyDirectoryName = "CC Pulse"

    private static func migrateLegacyDirectory() {
        guard ProcessInfo.processInfo.environment["CCPULSE_CONFIG_DIR"] == nil else { return }
        let fm = FileManager.default
        let target = directoryURL
        guard !fm.fileExists(atPath: target.path) else { return }
        let legacy = target.deletingLastPathComponent().appendingPathComponent(legacyDirectoryName, isDirectory: true)
        guard fm.fileExists(atPath: legacy.path) else { return }
        do {
            try fm.copyItem(at: legacy, to: target)
            try? fm.removeItem(at: target.appendingPathComponent("instance.pid"))
        } catch {
            NSLog("Kiteline: 迁移旧数据目录失败：\(error)")
        }
    }

    /// 数据目录只许自己进：里面有主令牌、设备令牌、TLS 私钥、点对点和推送密钥、日志。
    /// 老版本建的文件是 644，靠目录 700 一并挡住（~/Library 本身也是 700，这是多一层）
    private static func restrictDirectory() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    static func load() -> AppConfig {
        migrateLegacyDirectory()
        restrictDirectory()
        let url = fileURL
        if let data = try? Data(contentsOf: url),
           var config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            if config.mobile.token.isEmpty { config.mobile.token = MobileConfig.makeToken() }
            // 解码成功也要考虑落盘：老版本配置的迁移结果（sources / mobile）必须写回去，
            // 否则磁盘上一直是旧结构，用户下次手工编辑还会被再迁移一遍。
            config.saveIfChanged(from: data)
            return config
        }
        var fresh = AppConfig()
        fresh.mobile.token = MobileConfig.makeToken()
        fresh.jumpBackURI = detectJumpBackURI()
        fresh.save()
        return fresh
    }

    /// 只在内容确实变了时写盘，避免每次启动都动用户的配置文件
    private func saveIfChanged(from original: Data) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let fresh = try? encoder.encode(self) else { return }
        let unchanged: Bool = {
            guard let oldObject = try? JSONSerialization.jsonObject(with: original) as? [String: Any],
                  let newObject = try? JSONSerialization.jsonObject(with: fresh) as? [String: Any] else {
                return false
            }
            return NSDictionary(dictionary: oldObject).isEqual(to: newObject)
        }()
        if !unchanged {
            save()
            Log.write("配置已按新结构重写：\(AppConfig.fileURL.path)")
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: AppConfig.directoryURL, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self)
            try data.write(to: AppConfig.fileURL, options: .atomic)
            // 里面有主令牌：只有自己能读
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppConfig.fileURL.path)
        } catch {
            Log.write("配置写入失败: \(error.localizedDescription)")
        }
    }

    /// 从 VS Code 的 storage.json 里找出最近一次打开的远端窗口，用于「跳回项目」
    static func detectJumpBackURI() -> String? {
        let path = NSHomeDirectory() + "/Library/Application Support/Code/User/globalStorage/storage.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windows = root["windowsState"] as? [String: Any] else { return nil }

        var candidates: [String] = []
        if let opened = windows["openedWindows"] as? [[String: Any]] {
            for window in opened {
                if let folder = window["folder"] as? String, folder.contains("ssh-remote") {
                    candidates.append(folder)
                }
            }
        }
        if let last = windows["lastActiveWindow"] as? [String: Any],
           let folder = last["folder"] as? String, folder.contains("ssh-remote") {
            candidates.append(folder)
        }
        guard let raw = candidates.first else { return nil }
        return raw.removingPercentEncoding ?? raw
    }
}

/// 轻量日志，写到 Application Support 下的 ccpulse.log，便于排障。
///
/// 实现说明：必须用 O_APPEND 打开。早期版本用 FileHandle(forWritingTo:) + seekToEnd，
/// 多个实例同时写会各自维护偏移量、互相覆盖，排查问题时会被误导。
enum Log {
    private static let queue = DispatchQueue(label: "ccpulse.log")
    private static let url: URL = {
        let dir = AppConfig.directoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ccpulse.log")
    }()

    /// 日志超过这么大就把旧的挪成 ccpulse.log.1（只留一份）重新开始：里面有消息摘要，不该无限攒下去
    private static let maxBytes = 5 * 1024 * 1024

    static func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            let path = url.path
            if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > maxBytes {
                let old = path + ".1"
                try? FileManager.default.removeItem(atPath: old)
                try? FileManager.default.moveItem(atPath: path, toPath: old)
            }
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            _ = data.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.write(descriptor, base, buffer.count)
            }
        }
    }

    /// 等所有排队中的日志写完（退出/自检前调用，避免异步写入丢失）
    static func flush() {
        queue.sync {}
    }

    static func tail(_ lines: Int = 60) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "（暂无日志）" }
        let all = text.split(separator: "\n")
        return all.suffix(lines).joined(separator: "\n")
    }
}
