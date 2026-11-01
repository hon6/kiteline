import AppKit
import ApplicationServices
import Foundation
import ServiceManagement

/// 就绪检查：Kiteline 要完全用起来还差哪几步（Mac 这一侧的部分；手机自己的部分在网页里查）
enum Readiness {
    struct Item {
        var id: String
        var title: String
        /// ok / warn / bad
        var level: String
        var detail: String
        /// 怎么补
        var fix: String
    }

    static func check(completion: @escaping ([[String: Any]]) -> Void) {
        let state = AppState.shared
        let config = state.config
        var items: [Item] = []

        let ax = AXIsProcessTrusted()
        let axName = Delivery.accessibilityName
        items.append(Item(id: "accessibility", title: "电脑「\(axName)」权限", level: ax ? "ok" : "bad",
                          detail: ax ? "已授权：手机消息可送达会话并提交，可操作确认框" : "未授权：手机消息无法送达 VS Code 中已打开的会话，也无法点击「允许」",
                          fix: "在电脑上打开「系统设置 → 隐私与安全性 → \(axName)」，开启 Kiteline（若已开启但未生效：选中 Kiteline 并点击「−」删除，再在「Kiteline 设置 → 权限」中点击「打开系统设置」重新添加）"))

        let localDenied = LocalNetwork.status == .denied
        items.append(Item(id: "localnet", title: "电脑「本地网络」权限", level: localDenied ? "bad" : "ok",
                          detail: localDenied ? "未授权：同一 Wi-Fi 下的手机无法连接电脑，也无法连接局域网中的 Remote-SSH 主机（经中继的远程访问不受影响）"
                                              : "已授权：手机可在局域网中直连电脑",
                          fix: "在电脑上打开「系统设置 → 隐私与安全性 → 本地网络」，开启 Kiteline"))

        let adhoc = Self.isAdhocSigned()
        items.append(Item(id: "signing", title: "固定签名（授权跨版本保留）", level: adhoc ? "warn" : "ok",
                          detail: adhoc ? "当前为 ad-hoc 签名：每次更新后需重新授权\(axName)和语音识别" : "使用本机的固定签名身份，授权一次后更新时均会保留",
                          fix: "使用项目中的 build.sh / install.sh 重新构建并安装（将自动生成本机签名身份）"))

        let secure = state.mobile.secureStatus
        let httpsOK = config.mobile.httpsEnabled && secure.hasPrefix("监听中")
        items.append(Item(id: "https", title: "HTTPS 服务", level: httpsOK ? "ok" : "warn",
                          detail: httpsOK ? secure : "未开启或未启动（\(secure)）：锁屏推送、按住说话和离线外壳均需要 HTTPS",
                          fix: "在电脑上打开「Kiteline 设置 → 手机访问」；在手机上按「设置 → 推送通知」的提示安装一次证书"))

        let speech = Transcriber.status
        let local = config.mobile.voiceLocale == "zh-CN" && LocalASR.state == .ready
        items.append(Item(id: "speech", title: "语音识别（按住说话）", level: speech == "authorized" || local ? "ok" : "warn",
                          detail: local ? "已就绪，由电脑本机 Fun-ASR-Nano 模型离线转写"
                              : speech == "authorized" ? "已授权，由电脑本机离线转写" : "尚未授权（\(speech)），按住说话不可用",
                          fix: "在电脑上打开「系统设置 → 隐私与安全性 → 语音识别」，开启 Kiteline"))

        let summaries = state.sourceSummaries.filter { $0.config.enabled }
        let offline = summaries.filter { !$0.state.isLive }.map { $0.config.displayName }
        var stale: [String] = []
        for summary in summaries {
            if case .live(_, let watcher, _) = summary.state, let version = watcher, version != AppVersion.watcherScriptVersion {
                stale.append("\(summary.config.displayName)（\(version)）")
            }
        }
        items.append(Item(id: "sources", title: "各台机器", level: offline.isEmpty && stale.isEmpty ? "ok" : (offline.count == summaries.count ? "bad" : "warn"),
                          detail: offline.isEmpty && stale.isEmpty ? "\(summaries.count) 台均在线，观察器均为最新版本"
                            : [offline.isEmpty ? nil : "离线：\(offline.joined(separator: "、"))",
                               stale.isEmpty ? nil : "观察器版本过旧：\(stale.joined(separator: "、"))"].compactMap { $0 }.joined(separator: "；"),
                          fix: "在电脑菜单栏中右键 Kiteline →「重新连接」；并确认可免密 ssh 登录远端主机"))

        let editor = Delivery.Editor.running()
        items.append(Item(id: "vscode", title: "VS Code", level: editor != nil ? "ok" : "warn",
                          detail: editor != nil ? "运行中" : "未运行：新建任务时将自动打开；向 VS Code 中的会话发送消息需保持其运行",
                          fix: "在电脑上打开 VS Code"))

        // 扩展链接免确认（见 EditorSettings）：查的时候顺手设好；没装过 VS Code 的不列，测试实例只查不写
        let scheme = editor?.scheme ?? "vscode"
        if EditorSettings.installed(scheme: scheme) {
            let trusted = AppConfig.isolated ? EditorSettings.claudeLinksTrusted(scheme: scheme)
                                             : EditorSettings.trustClaudeLinks(scheme: scheme).trusted
            items.append(Item(id: "vscode-links", title: "VS Code 允许 Claude Code 打开链接", level: trusted ? "ok" : "bad",
                              detail: trusted ? "已允许：切换会话、新建任务时 VS Code 不会弹出确认框"
                                              : "未允许，且 VS Code 的设置文件无法自动修改：切换会话、新建任务时 VS Code 会先弹出确认框，人不在电脑前时消息无法送达",
                              fix: "在电脑上 VS Code 弹出「是否允许 Claude Code 扩展打开此 URI」时，勾选「不再询问」并点击「打开」；或在 VS Code 的用户设置（JSON）中加入 \"extensions.confirmedUriHandlerExtensionIds\": [\"anthropic.claude-code\"]"))
        }

        let login = SMAppService.mainApp.status == .enabled
        items.append(Item(id: "login", title: "登录时自动启动", level: login ? "ok" : "warn",
                          detail: login ? "已开启：电脑重启后 Kiteline 将自动启动" : "未开启：电脑重启后需手动打开 Kiteline，手机才能连接",
                          fix: "在电脑上打开「Kiteline 设置 → 通用」，开启「登录时自动打开 Kiteline」"))

        if !Projects.slowLocal.isEmpty {
            let names = Projects.slowLocal.prefix(3).map { Format.shortPath($0) }.joined(separator: "、")
            items.append(Item(id: "folders", title: "电脑文件夹访问权限", level: "warn",
                              detail: "无法读取 \(names)\(Projects.slowLocal.count > 3 ? " 等 \(Projects.slowLocal.count) 个项目" : "")：系统正在等待你允许 Kiteline 访问「文稿」/ 网络磁盘，项目状态、文件浏览和改动报告将无法加载",
                              fix: "在电脑上弹出的「Kiteline 想访问…」中点击「允许」；或在「系统设置 → 隐私与安全性 → 文件与文件夹」（或「完全磁盘访问权限」）中开启 Kiteline"))
        }

        let pushCount = state.mobile.push.subscriptions.count
        let bark = Bark.parse(config.mobile.barkURL) != nil
        items.append(Item(id: "push", title: "锁屏推送", level: pushCount > 0 || bark ? "ok" : "warn",
                          detail: [pushCount > 0 ? "\(pushCount) 台设备已开启网页推送" : "尚无设备开启网页推送",
                                   bark ? "Bark 备用推送已设置" : nil].compactMap { $0 }.joined(separator: "；"),
                          fix: "在手机上打开「设置 → 推送通知」并开启（需先使用 HTTPS 地址并添加到主屏幕）；或配置 Bark 备用推送"))

        let remote = P2P.shared.status
        let ownRelay = !AppState.shared.config.mobile.relayURL.isEmpty
        items.append(Item(id: "remote", title: "远程访问（不在同一 Wi-Fi 时连接）",
                          level: remote.online ? "ok" : "warn",
                          detail: !AppState.shared.config.mobile.remoteEnabled ? "未开启：手机仅能在同一 Wi-Fi 下连接"
                              : (remote.online ? (ownRelay ? "已连接自建中继" : "已连接 Kiteline 中继")
                                 : "尚未连接中继：\(remote.error ?? remote.state)"),
                          fix: "在电脑上打开「Kiteline 设置 → 远程访问」并开启；无法连接时请查看该页日志"))

        // Mac 会不会自动睡眠：睡着时手机连不上
        DispatchQueue.global(qos: .utility).async {
            let sleepMinutes = Self.systemSleepMinutes()
            DispatchQueue.main.async {
                var all = items
                if let minutes = sleepMinutes {
                    all.append(Item(id: "sleep", title: "电脑保持唤醒", level: minutes == 0 ? "ok" : "warn",
                                    detail: minutes == 0 ? "不会自动睡眠，手机可随时连接" : "闲置 \(minutes) 分钟后将进入睡眠，睡眠期间手机无法连接，定时任务也不会执行",
                                    fix: "在「系统设置 → 能耗」（或「电池 → 选项」）中开启「防止自动睡眠」"))
                }
                completion(all.map { ["id": $0.id, "title": $0.title, "level": $0.level, "detail": $0.detail, "fix": $0.fix] })
            }
        }
    }

    /// 自己是不是 ad-hoc 签名（codesign -dv 输出里有 Signature=adhoc）
    static func isAdhocSigned() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", Bundle.main.bundlePath]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.contains("Signature=adhoc") ?? false
    }

    /// pmset -g 里的 sleep 分钟数（0 = 不睡）；读不到返回 nil
    static func systemSleepMinutes() -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        for line in String(data: data, encoding: .utf8)?.split(separator: "\n") ?? [] {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, parts[0] == "sleep", let minutes = Int(parts[1]) { return minutes }
        }
        return nil
    }
}
