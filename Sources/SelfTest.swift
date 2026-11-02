import AppKit
import SwiftUI
import KitelineKit
import Foundation
import WebKit

/// 自检工具：离屏渲染界面为 PNG，并可选地走一遍真实的提醒链路。
///
/// 为什么需要它：开发环境的进程拿不到屏幕录制权限，无法截图；而界面正确性
/// 又必须验证。这里把 NSView 直接渲染成图片，既能在本机核对，也能给用户看。
enum SelfTest {

    // MARK: - 合成会话

    /// 造出跨来源的演示数据：本机两个 + 远端一台，用来核对来源标识与排序
    static func fakeRecords() -> [SessionRecord] {
        let localConfig = SourceConfig.local()
        let sshConfig = SourceConfig.ssh(host: "dev-vm", name: "虚拟机")
        return fakeSessions().enumerated().map { index, snapshot in
            let isLocal = index == 3   // 最后一个当本机，其余当远端
            let config = isLocal ? localConfig : sshConfig
            return SessionRecord(sourceId: config.id,
                                 sourceName: config.displayName,
                                 kind: config.kind,
                                 snapshot: snapshot)
        }
    }

    static func fakeSessions() -> [SessionSnapshot] {
        func make(_ dict: [String: Any]) -> SessionSnapshot {
            let data = try! JSONSerialization.data(withJSONObject: dict)
            return try! JSONDecoder().decode(SessionSnapshot.self, from: data)
        }
        return [
            make([
                "pid": 84980, "sessionId": "aaaa-1111", "name": "admin-72", "title": "订单导出功能",
                "entrypoint": "claude-vscode",
                "cwd": "/home/demo/projects/admin",
                "cwdShort": "~/projects/admin",
                "status": "waiting", "waitingFor": "等待你确认：Bash",
                "activity": "waiting",
                "reason": "等待你确认：Bash",
                "pendingTool": "Bash", "pendingId": "tool_B",
                "message": "我准备重建索引并重启服务，这条命令会修改线上数据。",
                "messageUuid": "msg-1", "version": "2.1.301",
                "startedAt": 1_792_163_612_757.0, "statusUpdatedAt": nowMinus(35),
                "transcriptPath": "/home/demo/.claude/projects/-home-demo-projects-admin/aaaa.jsonl",
            ]),
            make([
                "pid": 2941125, "sessionId": "bbbb-2222", "name": "shop-app-ce", "title": "首页卡片间距",
                "entrypoint": "claude-vscode", "activityText": "Bash: npm test -- --watch=false",
                "cwd": "/home/demo/projects/shop-app",
                "cwdShort": "~/projects/shop-app",
                "status": "busy", "activity": "busy",
                "reason": "正在跑 pnpm build，已持续 1 分 12 秒",
                "message": nil, "messageUuid": nil, "version": "2.1.296",
                "startedAt": 1_792_163_612_757.0, "statusUpdatedAt": nowMinus(72),
                "transcriptPath": "/home/demo/.claude/projects/-home-demo-projects-shop-app/bbbb.jsonl",
            ]),
            make([
                "pid": 2917660, "sessionId": "cccc-3333", "name": "shop-app-be", "title": "会员等级调整",
                "entrypoint": "claude-vscode",
                "cwd": "/home/demo/projects/shop-app",
                "cwdShort": "~/projects/shop-app",
                "status": "idle", "activity": "idle",
                "reason": "构建通过，可以发布了。",
                "message": "**实测效果**：会员等级规则已经改好，单元测试全部通过，代码已提交，main 也已推送。\n截图已发到你手机，确认没问题就可以发布了。",
                "messageUuid": "msg-3", "version": "2.1.296",
                "startedAt": 1_792_163_612_757.0, "statusUpdatedAt": nowMinus(240),
                "transcriptPath": "/home/demo/.claude/projects/-home-demo-projects-shop-app/cccc.jsonl",
            ]),
            make([
                "pid": 3001, "sessionId": "dddd-4444", "name": "tars-7", "title": "Kiteline 桌面客户端",
                "entrypoint": "claude-vscode",
                "cwd": "/Users/demo/Projects/tars", "cwdShort": "~/Projects/tars",
                "status": "idle", "activity": "idle",
                "message": "菜单栏面板和设置窗口都换成了液态玻璃风格，截图已发到你手机。",
                "messageUuid": "msg-4", "version": "2.1.301",
                "startedAt": 1_792_163_612_757.0, "statusUpdatedAt": nowMinus(3600 * 20),
                "transcriptPath": "/Users/demo/.claude/projects/x/dddd.jsonl",
            ]),
        ]
    }

    private static func nowMinus(_ seconds: Double) -> Double {
        (Date().timeIntervalSince1970 - seconds) * 1000
    }

    /// 今日动态的样例数据（和 watcher digest + Digest.collect 合并后的结构一致）
    static func fakeDigest() -> [String: Any] {
        let now = Date().timeIntervalSince1970 * 1000
        let records = fakeRecords()
        func session(_ index: Int, _ title: String, _ cwd: String, prompts: Int, files: [(String, Int)], tests: (Int, Int, Int),
                     tokens: Int, note: String, shots: Int, hoursAgo: Double, span: Double) -> [String: Any] {
            let record = records[index % records.count]
            var item: [String: Any] = [
                "sessionId": record.snapshot.sessionId, "sourceId": record.sourceId, "sourceName": record.sourceName,
                "title": title, "cwd": cwd, "prompts": prompts, "replies": prompts * 3, "requests": prompts * 9,
                "outputTokens": tokens, "fileCount": files.count, "images": shots,
                "files": files.map { ["path": $0.0, "edits": $0.1] },
                "conclusions": [["ts": now - hoursAgo * 3_600_000, "text": note]],
                "shots": (0..<shots).map { ["ref": "o\($0 * 100).0", "caption": "截图 \($0 + 1)", "ts": now] },
                "tests": ["runs": tests.0, "passed": tests.1, "failed": tests.2,
                          "last": tests.0 > 0 ? [["command": "npx vitest run", "description": "跑一遍单元测试",
                                                   "ok": tests.2 == 0, "passed": 12, "failed": tests.2 > 0 ? 1 : 0]] : []],
                "firstAt": now - (hoursAgo + span) * 3_600_000, "lastAt": now - hoursAgo * 3_600_000,
            ]
            if index < 2 { item["key"] = record.key; item["activity"] = record.snapshot.act.rawValue }
            return item
        }
        let sessions = [
            session(0, "首页卡片间距", "/Users/demo/projects/shop-app", prompts: 23,
                    files: [("src/styles/home.css", 3), ("src/components/Card.vue", 2), ("src/pages/index.vue", 1), ("tests/home.test.js", 1), ("README.md", 1), ("src/utils/size.js", 1)],
                    tests: (4, 3, 1), tokens: 186_000,
                    note: "首页卡片间距已经从 **4px 改成 16px**，圆角统一 12px。单元测试 12 项全部通过，截图已发到手机。", shots: 2, hoursAgo: 0.2, span: 3.5),
            session(1, "订单导出 Excel", "/Users/demo/projects/admin", prompts: 11,
                    files: [("server/api/orders/export.ts", 4), ("web/src/views/orders/List.vue", 2)],
                    tests: (2, 2, 0), tokens: 94_000,
                    note: "导出接口做好了：按当前筛选条件流式生成 xlsx，5 万行以上改为后台任务，完成后站内通知。", shots: 1, hoursAgo: 1.4, span: 2),
            session(2, "登录方案调研", "/Users/demo/projects/shop-app", prompts: 4, files: [], tests: (0, 0, 0), tokens: 12_000,
                    note: "对比了手机验证码、微信一键登录、账号密码三种方案，建议先上手机验证码。", shots: 0, hoursAgo: 5, span: 0.5),
        ]
        return ["ok": true, "since": now - 10 * 3_600_000, "until": 0, "generatedAt": now,
                "sessions": sessions, "totals": Digest.totals(sessions), "errors": []]
    }

    /// 额度样例（结构同 Limits.collect）：两台电脑，一台 Claude Code + Codex，一台 Claude Code 快用完
    static func fakeLimits() -> [String: Any] {
        let now = Date().timeIntervalSince1970 * 1000
        func window(_ kind: String, _ percent: Double, _ hours: Double) -> [String: Any] {
            ["kind": kind, "percent": percent, "resetsAt": now + hours * 3_600_000]
        }
        return ["ok": true, "generatedAt": now, "devices": [
            ["sourceId": "local", "name": "本机", "local": true, "agents": [
                ["agent": "claude-code", "at": now - 180_000, "windows": [window("five_hour", 42, 2.5), window("seven_day", 68, 20)]],
                ["agent": "codex", "at": now - 1_500_000, "plan": "plus", "windows": [window("five_hour", 18, 3.5), window("seven_day", 35, 90)]],
                ["agent": "deepseek-harness", "at": now - 300_000, "windows": [Any](), "balances": [
                    ["currency": "CNY", "amount": "18.5200", "kind": "main"], ["currency": "CNY", "amount": "5", "kind": "bonus"]]],
            ]],
            ["sourceId": "vm", "name": "虚拟机", "local": false, "agents": [
                ["agent": "claude-code", "at": now - 60_000, "windows": [window("five_hour", 86, 1), window("seven_day", 57, 130)]],
            ]],
        ]]
    }

    /// 用量报表样例（结构同 UsageReport.collect）
    static func fakeUsage() -> [String: Any] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let costs: [Double] = [18.2, 42.5, 0, 25.7, 98.8, 61.3, 115.7]
        let days: [[String: Any]] = costs.enumerated().map { index, cost in
            let date = Date().addingTimeInterval(Double(index - 6) * 86400)
            return ["day": formatter.string(from: date), "cost": cost, "estimated": index == 6 ? 87.8 : 0,
                    "requests": cost * 12, "output": cost * 11000, "cacheRead": cost * 2_700_000, "input": 0, "cacheWrite": cost * 30000]
        }
        let total = costs.reduce(0, +)
        return [
            "ok": true, "days": days, "range": 7,
            "totals": ["cost": total, "estimated": 87.8, "requests": total * 12, "output": total * 11000,
                       "cacheRead": total * 2_700_000, "cacheWrite": total * 30000, "input": 6000],
            "models": [["model": "claude-opus-5-5", "cost": total - 4.2, "requests": total * 11, "output": total * 10500, "cacheRead": total * 2_600_000],
                       ["model": "claude-haiku-5-5", "cost": 4.2, "requests": 120, "output": 18000, "cacheRead": 900_000]],
            "projects": [["name": "ccpulse", "cwd": "/home/demo/projects/ccpulse", "sourceName": "虚拟机", "cost": 214.6, "requests": 2400, "output": 2_300_000, "cacheRead": 560_000_000],
                         ["name": "admin", "cwd": "/home/demo/projects/admin", "sourceName": "开发机", "cost": 98.3, "requests": 1100, "output": 900_000, "cacheRead": 210_000_000],
                         ["name": "blog", "cwd": "/home/demo/blog", "sourceName": "虚拟机", "cost": 49.3, "requests": 520, "output": 260_000, "cacheRead": 90_000_000]],
            "sources": [["name": "虚拟机", "cost": 263.9, "requests": 2920], ["name": "开发机", "cost": 98.3, "requests": 1100]],
            "errors": [], "unpriced": [],
        ]
    }

    // MARK: - 离屏渲染

    /// 把界面渲染成 PNG（开发环境拿不到屏幕录制权限，用这个核对界面）。
    /// what：menubar / main / general / phone / sources / permissions / about
    static func render(_ what: String, to path: String, dark: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // 截图用的外观：TARS_LOOK=主题,字体,字号（如 ocean,serif,xl）；用单独一份偏好，不动正式 App 的
        if let spec = ProcessInfo.processInfo.environment["TARS_LOOK"], let scratch = UserDefaults(suiteName: "com.mrhong.tars.render") {
            let parts = spec.split(separator: ",").map(String.init)
            // 主题写成 #RRGGBB 就是自定义颜色
            if let first = parts.first, first.hasPrefix("#") {
                scratch.set("custom", forKey: "lookTheme")
                scratch.set(String(first.dropFirst()), forKey: "lookCustom")
            } else {
                scratch.set(parts.first ?? "classic", forKey: "lookTheme")
            }
            scratch.set(parts.count > 1 ? parts[1] : "system", forKey: "lookFont")
            scratch.set(parts.count > 2 ? parts[2] : "l", forKey: "lookSize")
            Look.shared.use(scratch)
        }
        let state = AppState.shared
        let localConfig = SourceConfig.local()
        let sshConfig = SourceConfig.ssh(host: "dev-vm", name: "虚拟机")
        state.store.applySourceConfigs([localConfig, sshConfig])
        state.store.apply(sourceConfig: localConfig, state: .live(host: "本机", watcher: AppVersion.watcherScriptVersion, sessionCount: 1))
        state.store.apply(sourceConfig: sshConfig, state: .live(host: "dev-vm", watcher: AppVersion.watcherScriptVersion, sessionCount: 3))
        state.store.injectForSelfTest(fakeRecords())
        KitelineModel.shared.refresh()
        // TARS_RENDER_MARK：按标题标记几个会话（逗号隔开，看星星、「标记」一组的样子；要配隔离的配置目录）
        if AppConfig.isolated, let titles = ProcessInfo.processInfo.environment["TARS_RENDER_MARK"] {
            for title in titles.split(separator: ",").reversed() {
                if let key = KitelineModel.shared.sessions.first(where: { $0.title == String(title) })?.id { state.setMarked(key, true) }
            }
        }

        let root: AnyView
        switch what {
        case "menubar": root = AnyView(MenuBarPanel(openMain: { _ in }, close: {}))
        case "general": root = AnyView(GeneralPane())
        case "phrases": root = AnyView(PhrasesPane())
        case "audit": root = AnyView(AuditPane())
        case "devices": root = AnyView(DevicesPane())
        case "watch": root = AnyView(WatchPane().background(Color(nsColor: .windowBackgroundColor)))
        case "schedules": root = AnyView(SchedulesPane())
        case "newtask":
            // 新任务面板：TARS_RENDER_IMAGES 逗号隔开的图片路径（预先附上），TARS_RENDER_SERVER 连上才有「听写」
            let env = ProcessInfo.processInfo.environment
            let server = env["TARS_RENDER_SERVER"].flatMap(URL.init(string:)) ?? URL(string: "http://127.0.0.1:9")!
            MainActor.assumeIsolated { KitelineKit.connect(baseURL: server, token: env["TARS_RENDER_TOKEN"] ?? "") }
            let images = (env["TARS_RENDER_IMAGES"] ?? "").split(separator: ",").compactMap { FileManager.default.contents(atPath: String($0)) }
            root = AnyView(NewTaskSheet(attach: images.compactMap { TarsTaskImage.make($0) }).background(Color(nsColor: .windowBackgroundColor)))
        case "usage":
            Limits.inject(fakeLimits())
            UsageReportModel.shared.inject(fakeUsage())
            root = AnyView(UsageReportView().frame(width: 880, height: 1100).background(Color(nsColor: .windowBackgroundColor)))
        case "history":
            let now = Date().timeIntervalSince1970 * 1000
            let samples: [[String: Any]] = [
                ["key": "local#a1", "sessionId": "a1", "sourceId": "local", "sourceName": "本机", "cwd": "/Users/demo/projects/shop-app",
                 "title": "首页卡片间距", "firstPrompt": "首页的卡片间距不对，你看下截图", "lastActive": now - 600_000, "live": true],
                ["key": "vm#b2", "sessionId": "b2", "sourceId": "vm", "sourceName": "虚拟机", "cwd": "/home/demo/projects/admin",
                 "title": "订单导出 Excel", "firstPrompt": "加一个订单导出 Excel 的功能，先出个方案", "lastActive": now - 5_400_000, "live": false],
                ["key": "local#c3", "sessionId": "c3", "sourceId": "local", "sourceName": "本机", "cwd": "/Users/demo/projects/shop-app",
                 "title": "登录页按钮改版", "firstPrompt": "登录页的按钮太小了，改大一点", "lastActive": now - 86_400_000 * 1.2, "live": false],
                ["key": "vm#d4", "sessionId": "d4", "sourceId": "vm", "sourceName": "虚拟机", "cwd": "/home/demo/projects/mini-program",
                 "title": "小程序预约推送", "firstPrompt": "小程序预约推送，和服务号推送，我记得有的吧", "lastActive": now - 86_400_000 * 3, "live": false],
            ]
            // TARS_RENDER_QUERY：画搜索结果（按项目名搜到的没有片段，下面写着「项目名称：…」）
            if let query = ProcessInfo.processInfo.environment["TARS_RENDER_QUERY"] {
                var found = samples
                found[0]["match"] = ["project"]
                found[2]["match"] = ["project"]
                found[1]["hits"] = [["id": "1.0", "ts": now - 5_500_000, "t": "user", "snippet": "顺便看下 \(query) 那边的订单接口"]]
                HistoryModel.shared.inject(samples.compactMap(PastItem.init), results: found.compactMap(PastItem.init), query: query)
            } else {
                HistoryModel.shared.inject(samples.compactMap(PastItem.init))
            }
            root = AnyView(HistoryView().frame(width: 820, height: 760).background(Color(nsColor: .windowBackgroundColor)))
        case "projects":
            let now = Date().timeIntervalSince1970 * 1000
            let samples: [[String: Any]] = [
                ["sourceId": "local", "sourceName": "本机", "cwd": "/Users/demo/projects/shop-app", "name": "shop-app", "sessionId": "a1",
                 "lastActive": now - 300_000, "sessions": 24, "today": 3,
                 "git": ["branch": "main", "upstream": "origin/main", "ahead": 2, "behind": 0, "changed": 5, "untracked": 1,
                         "last": ["hash": "3f9c2ab", "subject": "首页卡片改成两列", "ts": now - 3_600_000]]],
                ["sourceId": "vm", "sourceName": "虚拟机", "cwd": "/home/demo/projects/admin", "name": "admin", "sessionId": "b2",
                 "lastActive": now - 5_400_000, "sessions": 41, "today": 1,
                 "git": ["branch": "feat/export", "upstream": "origin/feat/export", "ahead": 0, "behind": 1, "changed": 0, "untracked": 0,
                         "last": ["hash": "b71e004", "subject": "订单导出 Excel：加上筛选条件", "ts": now - 7_200_000]]],
                ["sourceId": "vm", "sourceName": "虚拟机", "cwd": "/home/demo/projects/mini-program", "name": "mini-program", "sessionId": "d4",
                 "lastActive": now - 86_400_000 * 2, "sessions": 9, "today": 0,
                 "git": ["branch": "main", "upstream": "origin/main", "ahead": 0, "behind": 0, "changed": 0, "untracked": 0,
                         "last": ["hash": "0c4d9e1", "subject": "预约推送改用服务号模板消息", "ts": now - 86_400_000 * 2]]],
                ["sourceId": "local", "sourceName": "本机", "cwd": "/Users/demo/notes", "name": "notes", "sessionId": "e5",
                 "lastActive": now - 86_400_000 * 5, "sessions": 3, "today": 0, "title": "整理周报模板"],
            ]
            let items = samples.compactMap(ProjectItem.init)
            let past: [[String: Any]] = [
                ["key": "local#c3", "sessionId": "c3", "sourceId": "local", "sourceName": "本机", "cwd": "/Users/demo/projects/shop-app",
                 "title": "登录页按钮改版", "firstPrompt": "登录页的按钮太小了，改大一点", "lastActive": now - 86_400_000 * 1.2, "live": false],
                ["key": "local#c4", "sessionId": "c4", "sourceId": "local", "sourceName": "本机", "cwd": "/Users/demo/projects/shop-app",
                 "title": "购物车结算页", "firstPrompt": "结算页的优惠券要能叠加", "lastActive": now - 86_400_000 * 2.5, "live": false],
            ]
            ProjectsModel.shared.inject(items, cost: [items[0].id: 12.4, items[1].id: 3.85], expanded: items[0].id,
                                        past: [items[0].id: past.compactMap(PastItem.init)])
            root = AnyView(ProjectsView().frame(width: 820, height: 760).background(Color(nsColor: .windowBackgroundColor)))
        case "phone": root = AnyView(PhonePane())
        case "sources": root = AnyView(SourcesPane())
        case "permissions": root = AnyView(PermissionsPane())
        case "about": root = AnyView(AboutPane())
        case "licenses":
            // 开源许可窗口；TARS_RENDER_SELECT 选中一个组件（看许可原文）
            root = AnyView(LicensesView(select: ProcessInfo.processInfo.environment["TARS_RENDER_SELECT"])
                .frame(width: 860, height: 640).background(Color(nsColor: .windowBackgroundColor)))
        case "changelog":
            root = AnyView(TarsChangelogView(markdown: ChangelogWindowController.bundledText(), version: AppVersion.app)
                .frame(width: 700, height: Double(ProcessInfo.processInfo.environment["TARS_RENDER_HEIGHT"] ?? "") ?? 1400)
                .background(Color(nsColor: .windowBackgroundColor)))
        case "sidebar":
            Limits.inject(fakeLimits())
            // TARS_RENDER_SELECT：按标题选中一个会话（看选中的样子）
            if let title = ProcessInfo.processInfo.environment["TARS_RENDER_SELECT"] {
                KitelineModel.shared.selection = KitelineModel.shared.sessions.first { $0.title == title }?.id
            }
            // TARS_RENDER_SERVER / TARS_RENDER_TOKEN：连一个测试实例，「按来源」分组时机器名下面有它报的 CPU、内存、网速
            let env = ProcessInfo.processInfo.environment
            if let server = env["TARS_RENDER_SERVER"].flatMap(URL.init(string:)) {
                MainActor.assumeIsolated { KitelineKit.connect(baseURL: server, token: env["TARS_RENDER_TOKEN"] ?? "") }
            }
            // 同主窗口：上面盖一层纸鸢传信、风筝线（会话之间的消息）
            root = AnyView(SidebarView(model: KitelineModel.shared).frame(width: 300, height: 620)
                .background(Color(nsColor: .windowBackgroundColor))
                .overlay { KitelineKit.PeerStageView(order: KitelineModel.shared.filtered.map(\.id)) })
        case "chat":
            // 原生对话页：连一个正在跑的 Kiteline（测试实例）取数据。TARS_RENDER_SERVER / TARS_RENDER_TOKEN / TARS_RENDER_KEY
            let env = ProcessInfo.processInfo.environment
            if let server = env["TARS_RENDER_SERVER"].flatMap(URL.init(string:)) {
                MainActor.assumeIsolated { KitelineKit.connect(baseURL: server, token: env["TARS_RENDER_TOKEN"] ?? "") }
            }
            root = AnyView(TarsConversationView(key: env["TARS_RENDER_KEY"] ?? "")
                .frame(width: Double(env["TARS_RENDER_WIDTH"] ?? "") ?? 900, height: 820)
                .background(Color(nsColor: .windowBackgroundColor)))
        case "machine", "agentinfo":
            // 设备详情 / Agent 详情面板：连测试实例取数据。TARS_RENDER_SERVER / TARS_RENDER_TOKEN，
            // 设备详情看 TARS_RENDER_SOURCE（来源 id，默认 local），Agent 详情看 TARS_RENDER_KEY（会话 key）
            let env = ProcessInfo.processInfo.environment
            if let server = env["TARS_RENDER_SERVER"].flatMap(URL.init(string:)) {
                MainActor.assumeIsolated { KitelineKit.connect(baseURL: server, token: env["TARS_RENDER_TOKEN"] ?? "") }
            }
            let panel: AnyView = what == "machine" ? AnyView(TarsMachineInfoView(sourceId: env["TARS_RENDER_SOURCE"] ?? "local"))
                                                   : AnyView(TarsAgentInfoView(key: env["TARS_RENDER_KEY"] ?? ""))
            root = AnyView(panel.frame(width: 520, height: Double(env["TARS_RENDER_HEIGHT"] ?? "") ?? 900)
                .background(Color(nsColor: .windowBackgroundColor)))
        case "todos":
            // 待办页：连测试实例取数据（TARS_RENDER_SERVER / TARS_RENDER_TOKEN）。agent 待办的显示方式用 TARS_RENDER_GROUPING /
            // TARS_RENDER_SORTING / TARS_RENDER_SOURCE 指定，存在单独的偏好域里，不动正式版的设置
            let env = ProcessInfo.processInfo.environment
            if let server = env["TARS_RENDER_SERVER"].flatMap(URL.init(string:)) {
                MainActor.assumeIsolated { KitelineKit.connect(baseURL: server, token: env["TARS_RENDER_TOKEN"] ?? "") }
            }
            let prefs = UserDefaults(suiteName: "com.mrhong.tars.render") ?? .standard
            for (name, key) in [("TARS_RENDER_GROUPING", "todosGrouping"), ("TARS_RENDER_SORTING", "todosSorting"), ("TARS_RENDER_SOURCE", "todosSource")] {
                prefs.set(env[name].flatMap { $0.isEmpty ? nil : $0 }, forKey: key)
            }
            root = AnyView(TarsTodosView().defaultAppStorage(prefs)
                .frame(width: Double(env["TARS_RENDER_WIDTH"] ?? "") ?? 560, height: Double(env["TARS_RENDER_HEIGHT"] ?? "") ?? 820)
                .background(Color(nsColor: .windowBackgroundColor)))
        case "todoedit":
            // 「加入待办」面板（从一条消息加）：TARS_RENDER_TEXT 待办内容，TARS_RENDER_IMAGES 逗号隔开的图片路径
            let env = ProcessInfo.processInfo.environment
            let server = env["TARS_RENDER_SERVER"].flatMap(URL.init(string:)) ?? URL(string: "http://127.0.0.1:9")!
            MainActor.assumeIsolated { KitelineKit.connect(baseURL: server, token: env["TARS_RENDER_TOKEN"] ?? "") }
            let images = (env["TARS_RENDER_IMAGES"] ?? "").split(separator: ",").compactMap { FileManager.default.contents(atPath: String($0)) }
            root = AnyView(TarsTodoEditorPreview(text: env["TARS_RENDER_TEXT"] ?? "", source: env["TARS_RENDER_SOURCE"] ?? "iOS 应用 Wi-Fi 断开重连问题",
                                                 images: images)
                .background(Color(nsColor: .windowBackgroundColor)))
        case "today":
            if let report = DigestReport.decode(fakeDigest()) { TodayModel.shared.inject(report) }
            // 离屏渲染时 NSScrollView 不跟随深色外观画背景，这里垫一层窗口底色
            root = AnyView(TodayView().frame(width: 880, height: 1180).background(Color(nsColor: .windowBackgroundColor)))
        default: root = AnyView(MainView().frame(width: 1120, height: 720))
        }
        // 和真窗口一样：设置页、菜单栏面板的按钮包一层 LookButtonStyle，主窗口不包（工具栏）
        let hosting = NSHostingView(rootView: root.tarsLook(wrapButtons: what != "main" && what != "todoedit"))
        hosting.appearance = app.appearance
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: max(size.width, 200), height: max(size.height, 200)),
                              styleMask: what == "main" ? [.titled, .fullSizeContentView] : [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = app.appearance
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        if ProcessInfo.processInfo.environment["TARS_RENDER_ONSCREEN"] != nil {
            // 系统列表只给屏幕上的窗口排行：放进屏幕里，但全透明、鼠标穿透（用户看不见、也点不到）
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.setFrameOrigin(NSPoint(x: 60, y: 60))
        }
        window.orderFrontRegardless()
        // 对话页要等它连上、拉完历史
        RunLoop.current.run(until: Date().addingTimeInterval(what == "chat" || ProcessInfo.processInfo.environment["TARS_RENDER_SERVER"] != nil ? 5 : 1.5))
        let view = window.contentView!
        view.layoutSubtreeIfNeeded()
        // 固定按 2 倍出图（接的是非视网膜显示器时系统会按 1 倍画，和别的截图对不上）
        let bounds = view.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("已渲染 \(what) → \(path) (\(Int(view.bounds.width))×\(Int(view.bounds.height)))")
    }

    // MARK: - 提醒链路自检

    /// 按真实时间线灌入事件：首次基线 → 转为等待确认 → 出结论。
    /// 用来验证去重、冷却和系统通知是否真的弹出。
    static func runNotificationDrill() {
        let state = AppState.shared
        state.onStoreUpdate = { store in
            Log.write("[drill] \(store.summaryLine) / 等待 \(store.badgeCount)")
        }
        NotificationCenterBridge.shared.bootstrap()

        // 第 1 步：基线（不应提醒）
        state.store.injectForSelfTest(fakeRecords().filter { $0.snapshot.act == .busy })
        Log.write("[drill] 基线已建立（应当没有提醒）")

        // 第 2 步：转成「等你确认」
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let records = fakeRecords()
            state.store.injectForSelfTest(records.filter { $0.snapshot.act != .idle })
            Log.write("[drill] 注入 waiting（应弹出一条「需要你确认」）")
        }

        // 第 3 步：转成「出结论」
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            state.store.injectForSelfTest(fakeRecords().filter { $0.snapshot.act == .idle })
            Log.write("[drill] 注入 idle+结论（应弹出一条「有结论了」）")
        }
    }
}

// MARK: - 测试实例按脚本截主窗口

extension SelfTest {
    /// 测试实例（CCPULSE_DRY_RUN / 另指定配置目录）里按 TARS_CAPTURE_STEPS 操作主窗口并截图，用来核对原生对话页：
    /// "size:1120x760;select:<会话 key>;wait:4;shot:/tmp/a.png;action:files;wait:2;shot:/tmp/b.png;dark;quit"
    /// 窗口放在屏幕外：不显示在屏幕上、不抢焦点；也不记窗口位置（偏好设置和正式 App 共用这一项）
    @MainActor
    static func runCaptureScript() {
        guard AppConfig.isolated, let script = ProcessInfo.processInfo.environment["TARS_CAPTURE_STEPS"],
              let window = MainWindowController.shared.window else { return }
        window.setFrameAutosaveName("")
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        NativeConversation.setUp()
        KitelineKit.quietPanels { Log.write("[capture] \($0)") }   // 弹出的面板小窗不出现在用户屏幕上（截图照样截得到）
        KitelineKit.ropesInCapture = true   // 分屏里的信绳是图层，截图画不出来：让它直接画进截图
        step(script.split(separator: ";").map(String.init)[...], window)
    }

    @MainActor
    private static func step(_ steps: ArraySlice<String>, _ window: NSWindow) {
        guard let current = steps.first else { return }
        let parts = current.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts[0], arg = parts.count > 1 ? parts[1] : ""
        var delay = 0.3
        var next = window
        MainBusy.step = current
        switch name {
        case "perf":
            // 盯主线程：一轮连续忙超过 30 毫秒就记一笔（时长、当时在跑哪一步）；perf:report 汇总
            if arg == "report" { MainBusy.report() } else { MainBusy.start() }
        case "colpanel":
            // 把右边的分列单独放进一个不激活 App 也能成为 key 的面板（测试实例在后台，主窗口成不了 key，鼠标按下会被吞），
            // 之后的 drag / click / shot 都对这个面板：colpanel:1100x760
            let wh = arg.split(separator: "x").compactMap { Double($0) }
            let size = NSSize(width: wh.first ?? 1100, height: wh.count > 1 ? wh[1] : 760)
            let panel = NSPanel(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                                styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: TarsPanesView().frame(width: size.width, height: size.height))
            panel.orderFrontRegardless()
            panel.makeKey()
            next = panel
            delay = 2
        case "mainpanel":
            // 照主窗口另开一个面板（同样的标题栏、统一工具栏、MainView），不激活 App 也能成为 key：测标题栏那一带真的点不点得着
            //（测试实例在后台，主窗口成不了 key，第一下点击会被吞）。之后的 hit / click / drag / shot 都对它：mainpanel:1300x800
            let wh = arg.split(separator: "x").compactMap { Double($0) }
            let size = NSSize(width: wh.first ?? 1300, height: wh.count > 1 ? wh[1] : 800)
            let hosting = NSHostingController(rootView: MainView().tarsLook())
            hosting.sceneBridgingOptions = [.toolbars, .title]
            // 带标题栏的窗口一显示就会被系统挪回屏幕里：OffscreenPanel 不让挪，再设成全透明，万一出现在屏幕上也看不见
            let panel = OffscreenPanel(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                                       styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
            panel.alphaValue = 0
            panel.contentViewController = hosting
            panel.toolbarStyle = .unified
            panel.isReleasedWhenClosed = false
            panel.setContentSize(size)
            panel.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            panel.orderFrontRegardless()
            panel.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            panel.makeKey()
            Log.write("[capture] 主窗口副本在 \(panel.frame.origin)")
            next = panel
            delay = 3
        case "invisible":
            // 放进屏幕里（系统列表只给屏幕上的窗口排行），但全透明、鼠标穿透：用户看不见、也点不到。
            // 对主窗口用时顶上的纸鸢（子窗口）一起透明（kiteshot 按图层画，截出来照样有）
            for item in [window] + (window.childWindows ?? []) {
                item.alphaValue = 0
                item.ignoresMouseEvents = true
            }
            window.setFrameOrigin(NSPoint(x: 60, y: 60))
        case "tabmove":
            // 把会话（按标题）拖到当前块第几个标签的位置：tabmove:订单导出功能:0
            let bits = arg.split(separator: ":").map(String.init)
            if bits.count == 2, let index = Int(bits[1]), let item = KitelineModel.shared.sessions.first(where: { $0.title == bits[0] }) {
                KitelineKit.placeTab(item.id, at: index)
            }
        case "tabcmd":
            // 和按快捷键一样操作当前块的标签：tabcmd:new / close / next / previous / last / 3
            let commands: [String: KitelineKit.TabCommand] = ["new": .new, "close": .close, "next": .next, "previous": .previous, "last": .last]
            if let command = commands[arg] ?? Int(arg).map({ .select($0) }) { Log.write("[capture] 标签 \(arg)：\(KitelineKit.tab(command) ? "已执行" : "无可操作")") }
        case "size":
            let wh = arg.split(separator: "x").compactMap { Double($0) }
            if wh.count == 2 { window.setContentSize(NSSize(width: wh[0], height: wh[1])); window.setFrameOrigin(NSPoint(x: -20000, y: -20000)) }
        case "live", "liveleft":
            // 模拟用户拖窗口边缘调大小（系统的实时调整：期间 inLiveResize 为真，一点点变）：live:宽x高 拖右下角；liveleft 拖左边（右边不动）
            let wh = arg.split(separator: "x").compactMap { Double($0) }
            if wh.count == 2 {
                let start = window.frame, from = window.contentRect(forFrameRect: start).size
                let steps = 30
                window.perform(NSSelectorFromString("_startLiveResize"))
                for i in 1...steps {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.025 * Double(i)) {
                        let t = CGFloat(i) / CGFloat(steps)
                        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: from.width + (wh[0] - from.width) * t, height: from.height + (wh[1] - from.height) * t))
                        frame.origin = NSPoint(x: name == "liveleft" ? start.maxX - frame.width : start.minX, y: start.maxY - frame.height)
                        window.setFrame(frame, display: true)
                        if i == steps { window.perform(NSSelectorFromString("_endLiveResize")) }
                    }
                }
                delay = 0.025 * Double(steps) + 1
            }
        case "panelinvisible":
            // 弹出的面板也放进屏幕、全透明、鼠标穿透（同 invisible）：面板里的系统列表在屏幕外算不对行高
            for panel in KitelineKit.openPanels {
                panel.setFrameOrigin(NSPoint(x: 60, y: 60))
                panel.alphaValue = 0
                panel.ignoresMouseEvents = true
                panel.orderBack(nil)
            }
            delay = 1
        case "onscreen":
            // 放到屏幕里、压在所有窗口最底下（系统列表这类只给屏幕上看得见的行算高度，屏幕外截出来行会挤在一起）
            window.setFrameOrigin(NSPoint(x: 40, y: 40))
            window.orderBack(nil)
        case "pluginsexpand":
            // 设置 → 插件：兼容表全部展开（写在 settings:8 之前）
            PluginStore.expandAllForCapture = true
        case "pluginsoptin":
            // 设置 → 插件：只展开「接入方式」（默认不接的插件的说明）
            PluginStore.expandOptInForCapture = true
        case "plugin":
            // 插件开关（不经确认框，同确认后）：plugin:<id>:on / plugin:<id>:off
            let bits = arg.split(separator: ":").map(String.init)
            if bits.count == 2 { PluginStore.shared.setEnabled(bits[0], bits[1] == "on") }
        case "pluginerror":
            // 插件出错的弹窗：放进屏幕外、全透明的面板里画（不挂窗口 SwiftUI 不画），存成 pluginerror:<截图路径>
            let view = PluginErrorPanel.captureView()
            let panel = OffscreenPanel(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: view.frame.size),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.alphaValue = 0
            panel.contentView = view
            panel.isReleasedWhenClosed = false
            panel.orderFrontRegardless()
            panel.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { MainActor.assumeIsolated { write(view, to: arg); panel.orderOut(nil) } }
            delay = 1.2
        case "settings":
            // 设置窗口：settings:<页序号>:<截图路径>[:<滚到几成，0～1>]（等页面载完再截；长页面下面的分组用第三段滚过去再截）
            let bits = arg.split(separator: ":", maxSplits: 2).map(String.init)
            if let raw = Int(bits[0]), let tab = SettingsTab(rawValue: raw), let settings = SettingsWindowController.shared.showForCapture(tab: tab), bits.count > 1 {
                if bits.count > 2, let fraction = Double(bits[2]) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        MainActor.assumeIsolated {
                            guard let scroll = chatScrollView(in: settings.contentView), let document = scroll.documentView else { return }
                            let range = max(0, document.frame.height - scroll.contentView.bounds.height)
                            scroll.contentView.scroll(to: NSPoint(x: 0, y: range * min(max(fraction, 0), 1)))
                            scroll.reflectScrolledClipView(scroll.contentView)
                        }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { write(settings.contentView?.superview ?? settings.contentView, to: bits[1]) } }
                delay = 2.6
            }
        case "select": KitelineModel.shared.selection = arg
        case "group":
            // 会话群：group = 第一个群开进当前块的标签；group:split = 开在右侧分屏；group:drawer = 点标签栏上的成员按钮；group:list = 全部群；group:pick = 拉群面板（先勾上列表里前两个会话）；group:new = 点「建群」（什么都没勾）
            if arg == "list" { KitelineModel.shared.selection = KitelineModel.groupsID }
            else if arg == "new" { KitelineModel.shared.groupSeed = [] }
            else if arg == "members" { KitelineKit.showGroupMembersOnOpen(); if let id = KitelineKit.groupIDs.first { KitelineModel.shared.selection = KitelineModel.groupID(id) } }
            else if arg == "pick" { KitelineModel.shared.groupSeed = Array(KitelineModel.shared.sessions.prefix(2).map(\.id)) }
            else if arg == "split", let id = KitelineKit.groupIDs.first { KitelineKit.openSplit(KitelineModel.groupID(id), down: false); KitelineModel.shared.selection = KitelineModel.groupID(id) }
            else if arg == "drawer", let id = KitelineKit.groupIDs.first { KitelineKit.groupAction(id, "members") }
            else if let id = KitelineKit.groupIDs.first { KitelineModel.shared.selection = KitelineModel.groupID(id) }
            else { Log.write("[capture] 还没有会话群") }
        case "title":
            // 按标题选会话（测试数据每次重造，会话 id 会变）
            if let item = KitelineModel.shared.sessions.first(where: { $0.title == arg }) { KitelineModel.shared.selection = item.id }
            else if let past = HistoryModel.shared.sessions.first(where: { $0.displayTitle == arg }) { HistoryModel.shared.open(past) }   // 已结束的（先 select 历史页把列表载进来）
            else { Log.write("[capture] 没找到会话「\(arg)」") }
        case "wait": delay = Double(arg) ?? 1
        case "theme": Look.shared.themeID = arg   // 换主题色：theme:ocean（测试实例用自己那份偏好）
        case "font": Look.shared.fontID = arg   // 换字体：font:rounded / system（同设置 → 外观）
        case "lang": Lang.shared.choice = Lang.Choice(rawValue: arg) ?? .system   // 换界面语言：lang:en / zh / system（同设置里点）
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "action": if let action = KitelineKit.Action(rawValue: arg) { KitelineKit.perform(action, key: KitelineModel.shared.selection ?? "") }
        case "menu":
            // 点主菜单里的一项：menu:会话/在对话里搜索…（先记下这一组里每项能不能点）
            let parts = arg.split(separator: "/").map(String.init)
            if let top = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == parts[0] })?.submenu {
                top.update()
                Log.write("[capture] 菜单「\(parts[0])」：" + top.items.filter { !$0.isSeparatorItem }.map { "\($0.title)\($0.isEnabled ? "" : "（灰）")" }.joined(separator: "、"))
                if parts.count > 1, let index = top.items.firstIndex(where: { $0.title == parts[1] }) { top.performActionForItem(at: index) }
            }
        case "range": if let range = DigestRange(rawValue: arg) { TodayModel.shared.range = range }   // 今日动态的范围：today / yesterday / week
        case "split", "splitdown":
            // 分屏：把当前块一分为二放这个会话（按标题），split 左右分、splitdown 上下分；标题后加「:anim」= 带动画（同点按钮）
            let title = arg.hasSuffix(":anim") ? String(arg.dropLast(5)) : arg
            if let item = KitelineModel.shared.sessions.first(where: { $0.title == title }) {
                let open = { KitelineKit.openSplit(item.id, down: name == "splitdown") }
                if arg.hasSuffix(":anim") ? withAnimation(.snappy) { open() } : open() { KitelineModel.shared.selection = item.id } else { Log.write("[capture] 分不下「\(title)」") }
            } else { Log.write("[capture] 没找到会话「\(title)」") }
        case "newpane":
            // 点当前块的「一分为二」：newpane（自己判断方向）/ newpane:down / newpane:right
            if !KitelineKit.panes.splitFocused(down: arg.isEmpty ? nil : arg == "down") { Log.write("[capture] 分不下了") }
        case "uncol":
            // 关掉某一块（按标题）；标题后加「:anim」= 带动画（同点「×」）
            let title = arg.hasSuffix(":anim") ? String(arg.dropLast(5)) : arg
            if let item = KitelineModel.shared.sessions.first(where: { $0.title == title }) {
                if arg.hasSuffix(":anim") { withAnimation(.snappy) { KitelineKit.panes.close(key: item.id) } } else { KitelineKit.panes.close(key: item.id) }
            }
        case "drop", "ghost":
            // 把会话放到当前块的某一边（drop:标题:trailing），和从左边拖进来一样；ghost 只画「拖着停在那儿」的样子（ghost: 收起）
            let bits = arg.split(separator: ":").map(String.init)
            let item = bits.first.flatMap { title in KitelineModel.shared.sessions.first { $0.title == title } }
            if name == "drop", let item, bits.count > 1 {
                KitelineKit.dropOnFocused(item.id, zone: bits[1])
                KitelineModel.shared.selection = KitelineKit.panes.focused
            } else if name == "ghost" {
                KitelineKit.previewDrop(item?.id, zone: bits.count > 1 ? bits[1] : "")
            }
        case "cols": Log.write("[capture] 分屏：\(KitelineKit.panes.summary)；左边栏选中 \(KitelineModel.shared.selection ?? "-")")
        case "ropes": Log.write("[capture] 信绳：\(KitelineKit.ropeReport())")   // 分屏里连着两张信件的绳子在哪（拖它用）
        case "ropehover": KitelineKit.hoverRope(arg != "off")   // 当成鼠标停在第一根绳子那封信上：ropehover / ropehover:off
        case "effort":
            // 和在「模型和思考等级」里点某一档一样：effort:high（连点几次看会不会重复发）
            Log.write("[capture] 思考等级 \(arg)：\(KitelineKit.setEffort(key: KitelineModel.shared.selection ?? "", arg))")
        case "click", "drag", "vdrag":
            // 真的鼠标事件：click:x,y / drag:x,y,dx（左右拖）/ vdrag:x,y,dy（上下拖）（坐标从窗口左上角算）；drag:x,y,0,2 = 双击
            let n = arg.split(separator: ",").compactMap { Double($0) }
            if n.count >= 2 {
                let height = window.contentView?.bounds.height ?? window.frame.height
                let start = NSPoint(x: n[0], y: height - n[1])
                let dx = name == "drag" && n.count > 2 ? n[2] : 0
                let dy = name == "vdrag" && n.count > 2 ? -n[2] : 0   // 窗口坐标 y 朝上
                // 拖动直接交给窗口分发（不走系统事件队列）
                let target = name != "click" ? window.contentView?.hitTest(window.contentView?.convert(start, from: nil) ?? start) : nil
                func post(_ type: NSEvent.EventType, _ x: Double, _ y: Double, after: Double, clicks: Int = 1) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                        guard let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1) else { return }
                        if target != nil {
                            window.sendEvent(event)
                        } else {
                            NSApp.postEvent(event, atStart: false)
                        }
                    }
                }
                if let target { Log.write("[capture] 拖动：按在 \(type(of: target))，窗口 key=\(window.isKeyWindow)，App 活动=\(NSApp.isActive)") }
                window.makeKey()
                let moving = dx != 0 || dy != 0
                post(.leftMouseDown, start.x, start.y, after: 0)
                for i in 1...10 where moving { post(.leftMouseDragged, start.x + dx * Double(i) / 10, start.y + dy * Double(i) / 10, after: 0.05 * Double(i)) }
                post(.leftMouseUp, start.x + dx, start.y + dy, after: moving ? 0.6 : 0.08)
                if n.count > 3, n[3] == 2 {
                    post(.leftMouseDown, start.x, start.y, after: 0.15, clicks: 2)
                    post(.leftMouseUp, start.x, start.y, after: 0.2, clicks: 2)
                }
                delay = 1
            }
        case "dragto":
            // 按住从一点拖到另一点（坐标从窗口左上角算）：dragto:x1,y1,x2,y2[,停几秒再松手]——停着的时候后面的步骤照跑，能截到拖到一半的样子
            let n = arg.split(separator: ",").compactMap { Double($0) }
            if n.count >= 4 {
                let height = window.contentView?.bounds.height ?? window.frame.height
                let start = NSPoint(x: n[0], y: height - n[1]), end = NSPoint(x: n[2], y: height - n[3])
                let hold = n.count > 4 ? n[4] : 0
                func post(_ type: NSEvent.EventType, _ point: NSPoint, after: Double) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { return }
                        window.sendEvent(event)
                    }
                }
                window.makeKey()
                // 真用鼠标时指着标签窗口就拖不动（TabWindowLock）；这里没有悬停，照样先锁上，松手后还原
                let movable = window.isMovable
                window.isMovable = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8 + hold) { window.isMovable = movable }
                post(.leftMouseDown, start, after: 0)
                for i in 1...20 {
                    let t = Double(i) / 20
                    post(.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t), after: 0.03 * Double(i))
                }
                post(.leftMouseUp, end, after: 0.7 + hold)
                delay = hold > 0 ? 0.9 : 1.2
            }
        case "copyshown": KitelineKit.showCopyButtons()   // 代码块、命令、思考右上角的拷贝钮都画出来（放在打开会话之前）
        case "dividerhover": KitelineKit.showDividerHandles(arg != "off")   // 分屏的分隔线画成指针停在上面（看把手）；dividerhover:off 收起
        case "tabgeo": Log.write("[capture] 分屏位置：\n\(KitelineKit.tabGeometry)")
        case "esc":
            // 按一下 Esc（走 App 的事件队列，本地监听收得到）：拖标签拖到一半取消
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                NSApp.postEvent(event, atStart: false)
            }
        case "hit":
            // 排查用：窗口里这一点（从窗口左上角算）按下去落在哪个视图上：hit:x,y（工具栏那一带有没有挡住下面的标签栏）
            let n = arg.split(separator: ",").compactMap { Double($0) }
            if n.count == 2, let frame = window.contentView?.superview {
                var chain: [String] = []
                var view = frame.hitTest(NSPoint(x: n[0], y: frame.bounds.height - n[1]))
                while let current = view, chain.count < 5 {
                    chain.append(String(describing: type(of: current)).prefix(40) + (current.mouseDownCanMoveWindow ? "（可拖窗口）" : ""))
                    view = current.superview
                }
                Log.write("[capture] 按在 \(Int(n[0])),\(Int(n[1]))：\(chain.isEmpty ? "（无）" : chain.joined(separator: " ← "))")
            }
        case "chrome":
            // 排查用：标题栏 + 工具栏多高；chrome:transparent 把标题栏设成透明再看
            if arg == "transparent" { window.titlebarAppearsTransparent = true }
            if arg == "opaque" { window.titlebarAppearsTransparent = false }
            Log.write("[capture] 标题栏 + 工具栏 \(Int(window.frame.height - window.contentLayoutRect.maxY)) 点，透明 \(window.titlebarAppearsTransparent)，key \(window.isKeyWindow)，位置 \(window.frame.origin)，工具栏 \(window.toolbar.map { "\($0.items.count) 项" } ?? "无")")
        case "toast": KitelineKit.flash(arg)
        // 世界模式：world:on / off；worldjs:<脚本>（在世界的网页里跑，比如 World.world.view('rooms')）；worldshot:<png>（截网页，含 WebGL）
        case "world": KitelineModel.shared.setWorld(arg != "off", page: "world"); delay = 3
        case "flow": KitelineModel.shared.setWorld(arg != "off", page: "flow"); delay = 4
        case "sidebarcollapse": withAnimation(.snappy(duration: 0.32)) { SidebarState.shared.toggle() }; delay = 1   // 世界模式左上角的收起 / 展开会话列表
        case "worldjs":
            WorldHost.shared.webView.evaluateJavaScript(arg) { result, error in
                Log.write("[capture] 世界脚本：\(result.map { "\($0)" } ?? "-")\(error.map { " 出错 \($0)" } ?? "")")
            }
        case "worldshot":
            let config = WKSnapshotConfiguration()
            config.afterScreenUpdates = true
            WorldHost.shared.webView.takeSnapshot(with: config) { image, error in
                guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { Log.write("[capture] 世界截图失败 \(error.map { "\($0)" } ?? "")"); return }
                try? png.write(to: URL(fileURLWithPath: arg))
                Log.write("[capture] 世界截图 \(arg) \(Int(image.size.width))x\(Int(image.size.height))")
            }
            delay = 2
        case "image":
            // 在当前块打开看大图：image:<本机图片路径>[*张数]（同一张当几张，看翻页按钮）；之后 zoom:in / out / fit / actual / 2（倍数）
            let bits = arg.split(separator: "*").map(String.init)
            if let data = FileManager.default.contents(atPath: bits[0]) {
                KitelineKit.previewImage(Array(repeating: data, count: max(1, Int(bits.count > 1 ? bits[1] : "1") ?? 1)))
            } else { Log.write("[capture] 读不到图片 \(arg)") }
            delay = 2
        case "attach":
            // 往当前块的输入栏附图：attach:<本机图片路径>[*张数]（同粘贴截图）
            let bits = arg.split(separator: "*").map(String.init)
            if let data = FileManager.default.contents(atPath: bits[0]) {
                KitelineKit.attach(key: KitelineModel.shared.selection ?? "", Array(repeating: data, count: max(1, Int(bits.count > 1 ? bits[1] : "1") ?? 1)))
            } else { Log.write("[capture] 读不到图片 \(arg)") }
        case "zoom": Log.write("[capture] 缩放 \(arg)：\(KitelineKit.zoom(arg))")
        // 收藏：favlatest = 收藏当前会话最后一条文字回复和最后一条带图的消息；favopen:<第几条> = 点收藏页那条的「原消息」
        case "favlatest": Log.write("[capture] 收藏：\(KitelineKit.favoriteLatest(key: KitelineModel.shared.selection ?? ""))"); delay = 3
        case "favopen": Log.write("[capture] 打开收藏：\(KitelineKit.openFavorite(Int(arg) ?? 0))，左边栏选中 \(KitelineModel.shared.selection ?? "-")"); delay = 3
        case "panelsize":
            // 像用户拖边一样改最上面那个面板的大小（左上角不动）：panelsize:宽x高
            let wh = arg.split(separator: "x").compactMap { Double($0) }
            if wh.count == 2, let panel = KitelineKit.openPanels.last {
                panel.perform(NSSelectorFromString("_startLiveResize"))
                NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: panel)
                let frame = panel.frame
                // 拖边时系统先问代理能拖到多大（最小尺寸在这里拦）
                let size = panel.delegate?.windowWillResize?(panel, to: NSSize(width: wh[0], height: wh[1])) ?? NSSize(width: wh[0], height: wh[1])
                panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
                panel.perform(NSSelectorFromString("_endLiveResize"))
                Log.write("[capture] 面板改大小：要 \(arg)，实际 \(panel.frame.integral)")
            }
            delay = 1
        case "panel":
            // 之后的 hit / chrome / click / shot 都对最上面那个面板；顺带记下标题、红黄绿钮。
            // panel:vs 顺带挪到虚拟屏幕上（屏幕外的窗口缩放不了：系统按所在屏幕算大小）
            if let panel = KitelineKit.openPanels.last {
                next = panel
                if arg == "vs", let screen = NSScreen.screens.first(where: { $0.localizedName.contains("Kiteline") }) {
                    panel.setFrameOrigin(NSPoint(x: screen.frame.minX + 40, y: screen.frame.maxY - panel.frame.height - 40))
                }
                let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { kind -> String in
                    guard let button = panel.standardWindowButton(kind) else { return "无" }
                    return button.isHidden ? "藏" : (button.isEnabled ? "可用" : "灰")
                }
                Log.write("[capture] 面板「\(panel.title)」\(Int(panel.frame.width))×\(Int(panel.frame.height))，关闭/最小化/缩放：\(buttons.joined(separator: "/"))，"
                          + "工具栏 \(panel.toolbar.map { "\($0.items.count) 项" } ?? "无")，内容顶 \(Int(panel.frame.height - panel.contentLayoutRect.maxY)) 点")
            } else {
                Log.write("[capture] 没有开着的面板")
            }
        case "panelbutton":
            // 点最上面那个面板的红黄绿钮：panelbutton:close / zoom
            let kind: NSWindow.ButtonType = arg == "zoom" ? .zoomButton : .closeButton
            KitelineKit.openPanels.last?.standardWindowButton(kind)?.performClick(nil)
            Log.write("[capture] 点面板的 \(arg)；还开着 \(KitelineKit.openPanels.count) 个面板，最上面的 \(KitelineKit.openPanels.last.map { "\(Int($0.frame.width))×\(Int($0.frame.height))" } ?? "-")")
            delay = 1
        case "panelesc":
            // 对最上面那个面板按 Esc（同用户按）
            if let panel = KitelineKit.openPanels.last,
               let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                panel.sendEvent(event)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Log.write("[capture] 按 Esc 后还开着 \(KitelineKit.openPanels.count) 个面板") }
            }
            delay = 1
        case "panelweb":
            // 在最上面那个面板的网页视图（代码编辑器）里跑一段脚本：panelweb:KL.insert('x')
            var found: WKWebView?
            func walk(_ view: NSView) { if found == nil { if let web = view as? WKWebView { found = web } else { view.subviews.forEach(walk) } } }
            if let root = KitelineKit.openPanels.last?.contentView { walk(root) }
            found?.evaluateJavaScript(arg) { result, error in Log.write("[capture] 网页脚本 \(arg)：\(result.map { "\($0)" } ?? "-") \(error.map { "\($0)" } ?? "")") }
            if found == nil { Log.write("[capture] 面板里没有网页视图") }
            delay = 1
        case "update":
            // 检查更新：update:check / auto / begin / restart / phones / show（测试实例要给 CCPULSE_UPDATE_URL、CCPULSE_UPDATE_ANY=1）。
            // auto = 照每小时那次例行检查查（会按「不再提示」、24 小时规则自动弹）；phones = 打开「手机端有新版本」；
            // status = 只记一行状态；close = 关掉更新窗口（轮到手机的会接着弹）；skip = 勾上新版本的「此版本不再提示」
            switch arg {
            case "check": Updater.shared.check(manual: true)
            case "auto": Updater.shared.check()
            case "phones": UpdateWindowController.phones.show()
            case "status": break
            case "close": UpdateWindowController.shared.close()
            case "skip": if let version = Updater.shared.release?.version { Updater.shared.setSkipped(Updater.ownKey(version), true) }
            case "begin": Updater.shared.begin()
            case "restart": Updater.shared.restart()
            default: UpdateWindowController.shared.show()
            }
            Log.write("[capture] 更新：\(Updater.shared.phase.rawValue) \(Updater.shared.release?.version ?? "-") 已收 \(Updater.shared.received)，箭头\(Updater.shared.visible ? "显示" : "不显示")，" +
                      "更新窗口\(UpdateWindowController.shared.window?.isVisible == true ? "开着" : "没开")，手机窗口\(UpdateWindowController.phones.window?.isVisible == true ? "开着" : "没开")，" +
                      "落后 \(Updater.shared.release?.behind ?? 0) 版、说明 \(Updater.shared.release?.history.count ?? 0) 版，手机 \(Updater.shared.phones.map { "\($0.version) \($0.devices.map(\.name))" } ?? "-")")
        case "updateshot":
            if let panel = UpdateWindowController.shared.window { write(panel.contentView?.superview ?? panel.contentView, to: arg) }
        case "phoneshot":
            if let panel = UpdateWindowController.phones.window { write(panel.contentView?.superview ?? panel.contentView, to: arg) }
        case "open": KitelineKit.show(arg, key: KitelineModel.shared.selection ?? "")
        case "type": KitelineKit.setDraft(key: KitelineModel.shared.selection ?? "", arg)
        case "shot": capture(window, to: arg)
        case "glassshot":
            // 同 kiteshot，再补上液态玻璃（macOS 26 的侧栏）里的内容：整窗截图时系统不画玻璃里面，列表的字又是窗口服务器合成的，
            // 离屏怎么画都是空的——另开一个看不见的普通窗口，用同一份数据把侧栏单独画出来贴回去。要先 invisible（放进屏幕里列表才排行）
            KiteOverlay.shared.settleForCapture()
            let sidebar = glassSidebar(for: window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated {
                captureWithChildren(window, to: arg, sidebar: sidebar)
                sidebar?.orderOut(nil)
            } }
            delay = 3
        case "kiteshot":
            // 主窗口 + 顶上飞的纸鸢（子窗口）拼成一张：离屏时两个窗口分别画，再按真实位置叠起来，底下垫一层当桌面
            KiteOverlay.shared.settleForCapture()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { captureWithChildren(window, to: arg) } }
            delay = 1
        case "hoverrow":
            // 左边栏标题是 arg 的会话卡片画成鼠标停在上面（看右上角的「×」）
            SessionRow.captureHover = arg
            KitelineModel.shared.refresh()
        case "moveto":
            // 把窗口放到任意位置（Cocoa 坐标，左下角为原点），可选再设透明度：moveto:5300,-1300,0。
            // 查窗口被系统搬去虚拟屏幕又搬回来之后的样子：放上去不挪回来，好让撤屏、建屏时系统像对用户窗口那样搬它
            let values = arg.split(separator: ",").compactMap { Double($0) }
            if values.count >= 2 { window.setFrameOrigin(NSPoint(x: values[0], y: values[1])) }
            if values.count >= 3 { window.alphaValue = values[2] }
            Log.write("[capture] 窗口挪到 \(window.frame.origin)，在\(window.screen?.localizedName ?? "屏幕外")")
        case "sh":
            // 跑一个测试用的脚本（比如往测试数据的对话记录里追加一条新消息）
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", arg]
            try? process.run()
            process.waitUntilExit()
        case "views":
            // 排查用：列出窗口里和滚动有关的视图
            func walk(_ view: NSView, _ depth: Int) {
                let name = String(describing: type(of: view))
                if arg == "all" || name.contains("Scroll") || name.contains("Clip") {
                    let state = (view.isHidden ? " 隐藏" : "") + (view.alphaValue < 1 ? " 透明度 \(view.alphaValue)" : "")
                    Log.write("[capture] \(String(repeating: " ", count: depth))\(name) \(view.convert(view.bounds, to: nil).integral)\(state)")
                }
                view.subviews.forEach { walk($0, depth + 1) }
            }
            if let root = window.contentView { walk(root, 0) }
        case "layershot":
            // 按图层里现成的内容出图（不重画，和屏幕上合成出来的一样）：查息屏后气泡文字上下颠倒这类「层里画坏了」的问题
            if let root = (window.contentView?.superview ?? window.contentView)?.layer {
                let size = root.bounds.size
                if let ctx = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    ctx.scaleBy(x: 2, y: 2)
                    root.render(in: ctx)
                    if let image = ctx.makeImage() { try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg)) }
                }
            }
        case "flipdetach":
            // 实验：把 CGDrawingLayer 从图层树上摘下来当场重画再挂回去（模拟屏幕重新配置那一下层不在窗口里）
            var layers: [CALayer] = []
            func collect(_ layer: CALayer) {
                if NSStringFromClass(type(of: layer)).contains("CGDrawingLayer") { layers.append(layer) }
                layer.sublayers?.forEach(collect)
            }
            if let root = (window.contentView?.superview ?? window.contentView)?.layer { collect(root) }
            for layer in layers {
                guard let parent = layer.superlayer, let index = parent.sublayers?.firstIndex(of: layer) else { continue }
                layer.removeFromSuperlayer()
                layer.setNeedsDisplay()
                layer.displayIfNeeded()
                parent.insertSublayer(layer, at: UInt32(index))
            }
            Log.write("[capture] 摘下来重画了 \(layers.count) 个 CGDrawingLayer")
        case "layerhit":
            // 排查用：窗口里这一点（从窗口左上角算）是哪几层画的：layerhit:x,y
            let n = arg.split(separator: ",").compactMap { Double($0) }
            if n.count == 2, let root = (window.contentView?.superview ?? window.contentView)?.layer {
                let point = CGPoint(x: n[0], y: root.isGeometryFlipped ? n[1] : root.bounds.height - n[1])
                var hits: [String] = []
                func walk(_ layer: CALayer, _ depth: Int) {
                    if root.convert(layer.bounds, from: layer).contains(point), layer.contents != nil || layer.sublayers == nil {
                        hits.append("\(depth):\(NSStringFromClass(type(of: layer)).suffix(36))\(layer.contents == nil ? "" : "*")")
                    }
                    layer.sublayers?.forEach { walk($0, depth + 1) }
                }
                walk(root, 0)
                Log.write("[capture] \(Int(n[0])),\(Int(n[1])) 的层：\(hits.suffix(8).joined(separator: " | "))")
            }
        case "send": KitelineKit.send(key: KitelineModel.shared.selection ?? "", arg)
        case "pending": Log.write("[capture] 未回显的消息：\(KitelineKit.pendingStates(key: KitelineModel.shared.selection ?? ""))")
        case "keyhold":
            // 投递期间截键（KeyHold）：截 0.4 秒，期间发一个不带标记的 F18（应截下）和一个带标记的（应放行），再放开、补发给前台程序。
            // F18 没有默认用途，补发到用户正在用的程序里也不会有反应
            KeyHold.begin(limit: 3)
            for marked in [false, true] {
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 79, keyDown: down)
                    if marked { event?.setIntegerValueField(.eventSourceUserData, value: KeyHold.marker) }
                    event?.post(tap: .cghidEventTap)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                Log.write("[capture] 截键：截下 \(KeyHold.heldCount) 个事件（应为 2：不带标记的按下、松开）")
                KeyHold.end(target: nil)
            }
            delay = 1.5
        case "liveshot":
            // 最上面那个面板（没有就主窗口）挪到虚拟屏幕上（用户看不见）真的合成一次再截：液态玻璃的分组底离屏画不出来，
            // 按钮贴不贴边只有这样看得准
            let target = KitelineKit.openPanels.last ?? window
            if let screen = NSScreen.screens.first(where: { $0.backingScaleFactor == 1 && $0.localizedName.contains("Kiteline") }) {
                let origin = target.frame.origin
                target.setFrameOrigin(NSPoint(x: screen.frame.minX + 40, y: screen.frame.maxY - target.frame.height - 40))
                target.alphaValue = 1
                target.orderFrontRegardless()
                // 当前窗口的工具栏才是用户平时看到的样子（没激活的整体发灰）：测试实例在后台，面板要能不激活 App 就成为 key
                (target as? NSPanel)?.styleMask.insert(.nonactivatingPanel)
                target.makeKey()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    composited(target, to: arg)
                    // 挂着的确认框（单独的窗口）另存一张
                    if let sheet = target.attachedSheet { composited(sheet, to: arg.replacingOccurrences(of: ".png", with: "-sheet.png")) }
                    target.setFrameOrigin(origin)
                }
            } else {
                // 没有虚拟屏幕（正式版没在用时会撤掉）：原地截。屏幕外的窗口窗口服务器照样合成，细线、遮挡看得准，液态玻璃可能不全
                Log.write("[capture] 没有虚拟屏幕，原地截")
                composited(target, to: arg)
            }
            delay = 2.5
        case "screenchange":
            // 和显示器接上 / 拔掉时一样发一次「屏幕参数变了」（只在本进程里，不动真的显示器）
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        case "redraw":
            let start = Date()
            let count = ScreenRedraw.redrawAll()
            CATransaction.flush()
            Log.write("[capture] 重画 \(count) 个 CGDrawingLayer，用时 \(Int(Date().timeIntervalSince(start) * 1000)) 毫秒")
        case "scrollto":
            // 直接把对话区滚到顶 / 底（top / bottom / 数字 = 离顶多少点）
            if let view = chatScrollView(in: window.contentView), let document = view.documentView {
                let maxY = max(0, document.frame.height - view.contentView.bounds.height)
                let y: CGFloat = arg == "top" ? 0 : (arg == "bottom" ? maxY : CGFloat(Double(arg) ?? 0))
                view.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? y : maxY - y))
                view.reflectScrolledClipView(view.contentView)
                Log.write("[capture] 滚到 \(arg)：可见区域 y=\(Int(view.contentView.bounds.origin.y))，内容高 \(Int(document.frame.height))")
            }
        case "scroll":
            // 在对话区模拟一次触控板滑动：正数往上翻（看更早的），负数往下
            if let view = chatScrollView(in: window.contentView) { swipe(view, by: Double(arg) ?? 600) }
        case "cpumark":
            // 记从上一个 cpumark 到现在进程用了多少 CPU（量一次操作后台总共忙了多久，零碎的小块也算上）：cpumark:<名字>
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let now = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000 + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
            if let last = CPUMark.last { Log.write(String(format: "[capture] CPU %@：%.0f 毫秒", arg, now - last)) }
            CPUMark.last = now
        case "sidebarscroll":
            // 像真人一样逐帧滚左边的会话列表（往下滚一半时间、再滚回来），记主线程用了多少 CPU：sidebarscroll:<秒>[:hover]
            // hover：鼠标停在列表中间（每帧补一个鼠标移动事件，行从鼠标底下滑过时悬停效果照常进出）
            let bits = arg.split(separator: ":")
            let seconds = bits.first.flatMap { Double($0) } ?? 4
            if let view = sidebarScrollView(in: window.contentView) {
                sidebarScroll(view, seconds: seconds, hover: bits.contains("hover"))
                delay = seconds + 1
            } else {
                Log.write("[capture] 没找到会话列表的滚动视图")
            }
        case "close":
            // 关掉挂着的面板：按一下 Esc（面板小窗关最上面那个）
            if !KitelineKit.openPanels.isEmpty {
                KitelineKit.closeTopPanel()
            } else if let sheet = window.attachedSheet,
               let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: sheet.windowNumber,
                                          context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                sheet.sendEvent(esc)
            }
        case "quit": exit(0)   // 测试实例截完就走（正常退出会被拦下来问）
        default: Log.write("[capture] 不认识的步骤：\(current)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { step(steps.dropFirst(), next) }
    }

    /// 窗口服务器真正合成出来的样子（liveshot）：截自己的窗口不用屏幕录制权限；CGWindowListCreateImage 新 SDK 里标成不可用，按名字取
    @MainActor
    private static func composited(_ window: NSWindow, to path: String) {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        // kCGWindowListOptionIncludingWindow = 8，kCGWindowImageBoundsIgnoreFraming = 1
        if let image = capture(.null, 8, CGWindowID(window.windowNumber), 1)?.takeRetainedValue() {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            Log.write("[capture] 真实合成截图 \(path)：\(image.width)×\(image.height)")
        } else { Log.write("[capture] 真实合成截图失败") }
    }

    /// 把窗口（连标题栏、工具栏）画成 2 倍图；挂着的面板另存一张 -sheet.png
    @MainActor
    private static func capture(_ window: NSWindow, to path: String) {
        write(window.contentView?.superview ?? window.contentView, to: path)
        if let sheet = window.attachedSheet {
            write(sheet.contentView?.superview ?? sheet.contentView, to: path.replacingOccurrences(of: ".png", with: "-sheet.png"))
        }
        // 弹出的面板小窗（能拖动、改大小的那种）：-panel.png、-panel2.png……，记下它和主窗口的位置（核对是否对着会话居中）
        for (i, panel) in KitelineKit.openPanels.enumerated() {
            write(panel.contentView?.superview ?? panel.contentView, to: path.replacingOccurrences(of: ".png", with: i == 0 ? "-panel.png" : "-panel\(i + 1).png"))
            Log.write("[capture] 面板 \(i + 1)：\(panel.frame.integral)，中心 \(Int(panel.frame.midX)),\(Int(panel.frame.midY))，主窗口 \(window.frame.integral)，可改大小 \(panel.styleMask.contains(.resizable))，工具栏 \(panel.toolbar == nil ? "无" : "有")")
            for item in panel.toolbar?.items ?? [] {
                Log.write("[capture]   工具栏项 \(item.itemIdentifier.rawValue.suffix(40))：view \(item.view.map { "\($0.frame.integral) \(type(of: $0))" } ?? "无")")
            }
        }
        if let toast = KitelineKit.toastView {
            write(toast, to: path.replacingOccurrences(of: ".png", with: "-toast.png"))
            if let panel = toast.window { Log.write("[capture] 小提示在 \(panel.frame.integral)，窗口 \(window.frame.integral)，子窗口 \(window.childWindows?.count ?? 0)") }
        }
    }

    @MainActor
    private static func captureWithChildren(_ window: NSWindow, to path: String, sidebar: NSWindow? = nil) {
        let windows = [window] + (window.childWindows ?? []).filter(\.isVisible)
        let union = windows.reduce(window.frame) { $0.union($1.frame) }.insetBy(dx: -30, dy: -30)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(union.width * 2), pixelsHigh: Int(union.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = union.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(colors: [NSColor(srgbRed: 0.80, green: 0.78, blue: 0.75, alpha: 1), NSColor(srgbRed: 0.55, green: 0.63, blue: 0.74, alpha: 1)])?
            .draw(in: NSRect(origin: .zero, size: union.size), angle: 90)
        for item in windows {
            guard let view = item.contentView?.superview ?? item.contentView else { continue }
            view.layoutSubtreeIfNeeded()
            let bounds = view.bounds
            guard let sub = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            sub.size = bounds.size
            if item !== window, let content = item.contentView, let layer = content.layer, !(content is NSHostingView<AnyView>) {
                // 图层托管的视图（顶上的纸鸢）：cacheDisplay 画不出自己加的子图层，直接让图层画
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sub)
                // 位图的 size 是点、像素是 2 倍，上下文已经按 2 倍换算好了
                if let cg = NSGraphicsContext.current?.cgContext { layer.render(in: cg) }
                NSGraphicsContext.restoreGraphicsState()
            } else {
                view.cacheDisplay(in: bounds, to: sub)
                if let sidebar, item === window { drawGlassContents(in: view, onto: sub, sidebar: sidebar) }
            }
            sub.draw(in: NSRect(x: item.frame.minX - union.minX, y: item.frame.minY - union.minY, width: item.frame.width, height: item.frame.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        Log.write("[capture] \(path) 主窗口 \(window.frame.integral)，子窗口 \(windows.dropFirst().map { $0.frame.integral })")
    }

    /// 侧栏单独画在一个看不见的普通窗口里（放进屏幕、全透明、鼠标穿透），大小、上面让出的高度（标题栏 + 搜索框）照主窗口里的玻璃
    @MainActor
    private static func glassSidebar(for window: NSWindow) -> NSWindow? {
        guard #available(macOS 26, *), let root = window.contentView?.superview ?? window.contentView else { return nil }
        func find(_ view: NSView) -> NSGlassEffectView? {
            if let glass = view as? NSGlassEffectView, glass.bounds.width > 200 { return glass }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let glass = find(root) else { return nil }
        let size = glass.bounds.size
        // 列表从搜索框下面开始：滚动视图顶上那条渐隐（BackdropView）的高度
        func backdrop(_ view: NSView) -> CGFloat? {
            if String(describing: type(of: view)) == "BackdropView" { return view.bounds.height }
            return view.subviews.lazy.compactMap(backdrop).first
        }
        let top = backdrop(glass) ?? 98
        let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let hosting = NSHostingView(rootView: SidebarView(model: KitelineModel.shared).padding(.top, top)
            .frame(width: size.width, height: size.height).tarsLook())
        hosting.appearance = window.effectiveAppearance
        let helper = NSWindow(contentRect: NSRect(x: 60, y: 60, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        helper.appearance = window.effectiveAppearance
        helper.backgroundColor = NSColor(white: dark ? 0.17 : 0.95, alpha: 1)
        helper.contentView = hosting
        helper.alphaValue = 0
        helper.ignoresMouseEvents = true
        helper.isReleasedWhenClosed = false
        helper.orderFrontRegardless()
        return helper
    }

    /// 把单独画好的侧栏贴到主窗口的侧栏玻璃上；再把标题栏那一排（红绿灯、新任务按钮）重画一遍，搜索框按深浅色补画
    @MainActor
    private static func drawGlassContents(in root: NSView, onto rep: NSBitmapImageRep, sidebar: NSWindow) {
        guard #available(macOS 26, *), let side = sidebar.contentView else { return }
        var glasses: [NSGlassEffectView] = []
        var titlebar: NSView?
        var search: NSView?
        func find(_ view: NSView) {
            let name = String(describing: type(of: view))
            if titlebar == nil, name == "NSTitlebarContainerView" { titlebar = view }
            if search == nil, view is NSSearchField { search = view }
            if let glass = view as? NSGlassEffectView { glasses.append(glass) }
            view.subviews.forEach(find)
        }
        find(root)
        let dark = root.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        func snapshot(_ view: NSView) -> NSBitmapImageRep? {
            view.layoutSubtreeIfNeeded()
            let bounds = view.bounds
            guard let piece = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            piece.size = bounds.size
            view.cacheDisplay(in: bounds, to: piece)
            return piece
        }
        let sideImage = snapshot(side)
        let titleImage = titlebar.flatMap(snapshot)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        if let big = glasses.first(where: { $0.bounds.width > 200 }), let sideImage {
            let rect = big.convert(big.bounds, to: root)
            let fill = NSColor(white: dark ? 0.17 : 0.95, alpha: 1)
            fill.setFill()
            rect.fill()
            sideImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            // 底部那排按钮（来源、手机、设置）：真窗口里底下有一层模糊，单独画的没有、会和列表叠在一起——垫一条底色（上沿渐隐），
            // 再贴主窗口里原来那一排（玻璃里的内容只有列表画不出来，按钮画得出来）
            let footer = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 50)
            NSGradient(starting: fill.withAlphaComponent(0), ending: fill)?.draw(in: NSRect(x: footer.minX, y: footer.maxY, width: footer.width, height: 18), angle: -90)
            fill.setFill()
            footer.fill()
            if let content = big.contentView, let original = snapshot(content) {
                let frame = content.convert(content.bounds, to: root)
                NSGraphicsContext.saveGraphicsState()
                footer.clip()
                original.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        if let titlebar, let titleImage {
            titleImage.draw(in: titlebar.convert(titlebar.bounds, to: root), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            // 标题栏里的玻璃按钮（新任务）：底下补一个圆，再把按钮里的图标画上去
            for glass in glasses where glass.isDescendant(of: titlebar) {
                let rect = glass.convert(glass.bounds, to: root)
                NSColor(white: dark ? 0.26 : 0.99, alpha: 1).setFill()
                NSBezierPath(roundedRect: rect, xRadius: glass.cornerRadius, yRadius: glass.cornerRadius).fill()
                if let content = glass.contentView, let icon = snapshot(content) {
                    icon.draw(in: content.convert(content.bounds, to: root), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            }
        }
        // 分段控件（今日动态的「今天 / 昨天 / 近 7 天」）：选中那一格也是玻璃，字跟着画不出来——补一块浅色底，把字写上
        var segments: [NSSegmentedControl] = []
        func findSegments(_ view: NSView) {
            if let control = view as? NSSegmentedControl { segments.append(control) }
            view.subviews.forEach(findSegments)
        }
        findSegments(root)
        for control in segments where control.selectedSegment >= 0 && control.segmentCount > 0 {
            let rect = control.convert(control.bounds, to: root)
            let width = rect.width / CGFloat(control.segmentCount)
            let cell = NSRect(x: rect.minX + width * CGFloat(control.selectedSegment), y: rect.minY, width: width, height: rect.height).insetBy(dx: 2, dy: 2)
            NSColor(white: dark ? 0.36 : 1, alpha: 1).setFill()
            NSBezierPath(roundedRect: cell, xRadius: cell.height / 2, yRadius: cell.height / 2).fill()
            let label = NSAttributedString(string: control.label(forSegment: control.selectedSegment) ?? "",
                                           attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor(white: dark ? 0.96 : 0.1, alpha: 1)])
            let size = label.size()
            label.draw(at: NSPoint(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2))
        }
        if let search {
            // 搜索框：玻璃胶囊 + 放大镜 + 提示文字
            let rect = search.convert(search.bounds, to: root)
            NSColor(white: dark ? 0.24 : 0.88, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            let gray = NSColor(white: dark ? 0.62 : 0.45, alpha: 1)
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular).applying(.init(paletteColors: [gray]))
            if let glassIcon = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                glassIcon.draw(in: NSRect(x: rect.minX + 11, y: rect.midY - glassIcon.size.height / 2, width: glassIcon.size.width, height: glassIcon.size.height))
            }
            let prompt = (search as? NSSearchField)?.placeholderString ?? "搜索会话"
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: gray]
            let text = NSAttributedString(string: prompt, attributes: attributes)
            text.draw(at: NSPoint(x: rect.minX + 32, y: rect.midY - text.size().height / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
        Log.write("[capture] 侧栏贴图 \(glasses.map { $0.convert($0.bounds, to: root).integral })，搜索框 \(search.map { $0.convert($0.bounds, to: root).integral } ?? .zero)")
    }

    @MainActor
    private static func write(_ view: NSView?, to path: String) {
        guard let view else { return }
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        pasteWebViews(in: view, onto: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        Log.write("[capture] \(path) \(Int(bounds.width))×\(Int(bounds.height))")
    }

    /// 网页视图（代码 IDE 的编辑器、世界模式）在 WebKit 自己的进程里画，cacheDisplay 只截到空白：逐个取快照贴回原位
    @MainActor
    private static func pasteWebViews(in root: NSView, onto rep: NSBitmapImageRep) {
        var webs: [WKWebView] = []
        func walk(_ view: NSView) {
            if let web = view as? WKWebView { webs.append(web); return }
            view.subviews.forEach(walk)
        }
        walk(root)
        guard !webs.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // SwiftUI 的 .opacity(0) 落在上层视图的图层上（alphaValue 不变）：一路往上乘，看不见的（藏起来的编辑器）别贴
        func opacity(_ view: NSView) -> CGFloat {
            var value: CGFloat = 1
            var node: NSView? = view
            while let current = node, current !== root {
                value *= current.alphaValue * CGFloat(current.layer?.opacity ?? 1)
                node = current.superview
            }
            return value
        }
        for web in webs where !web.isHiddenOrHasHiddenAncestor && opacity(web) > 0.01 && web.bounds.width > 1 {
            var image: NSImage?
            var done = false
            web.takeSnapshot(with: nil) { snapshot, _ in image = snapshot; done = true }
            let deadline = Date().addingTimeInterval(3)
            while !done && Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
            guard let image else { Log.write("[capture] 网页视图快照失败"); continue }
            var frame = web.convert(web.bounds, to: root)
            if root.isFlipped { frame.origin.y = root.bounds.height - frame.maxY }
            image.draw(in: frame)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 对话区的滚动视图：主窗口右边最大的那个
    private static func chatScrollView(in root: NSView?) -> NSScrollView? {
        guard let root else { return nil }
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(root)
        // SwiftUI 的滚动视图（HostingScrollView）里最大的那个；macOS 26 起详情区铺满整个窗口（左边栏浮在上面）
        return found.filter { String(describing: type(of: $0)).contains("Hosting") }
            .max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    /// 一次完整的两指滑动：开始 → 若干次移动 → 结束（和真的触控板一样带手势阶段）
    private static func swipe(_ view: NSScrollView, by distance: Double) {
        let moves = 10
        for index in 0...(moves + 1) {
            let delta = index == 0 || index == moves + 1 ? 0 : distance / Double(moves)
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(delta), wheel2: 0, wheel3: 0) else { continue }
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(delta))
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: delta)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: index == 0 ? 1 : (index == moves + 1 ? 4 : 2))
            if let ns = NSEvent(cgEvent: event) { view.scrollWheel(with: ns) }
        }
        Log.write("[capture] 滑动 \(Int(distance))：\(type(of: view)) 可见区域 y=\(Int(view.contentView.bounds.origin.y))")
    }

    /// 左边会话列表（系统列表）的滚动视图：文档视图是表格、靠窗口左边的那个
    private static func sidebarScrollView(in root: NSView?) -> NSScrollView? {
        guard let root else { return nil }
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, scroll.documentView is NSTableView { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found.min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    /// 逐帧挪会话列表的可见区域（每帧一次，同手指拖着滚），前一半往下滚到底、后一半滚回顶；结束时记这段时间进程用掉的 CPU
    private static func sidebarScroll(_ view: NSScrollView, seconds: Double, hover: Bool = false) {
        let frames = max(Int(seconds * 60), 4)
        let half = frames / 2
        let cpu = { () -> Double in
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000 + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
        }
        let clip = view.contentView
        let top = clip.bounds.origin.y
        let bottom = max(top, (view.documentView?.frame.height ?? 0) - clip.bounds.height)
        Log.write("[capture] 侧栏 \((view.documentView as? NSTableView)?.numberOfRows ?? -1) 行，可滚 \(Int(top))…\(Int(bottom))")
        // 鼠标停在列表正中：每帧发给那一点上的视图一个鼠标移动事件（同真的鼠标不动、内容从底下滑过）
        let window = view.window
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        var loggedTarget = false
        let moveMouse = {
            guard hover, let window, let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return }
            // 在列表里找那一点上最深的视图，往上找到第一个 SwiftUI 宿主（列表每行一个）发给它
            let deepest = view.superview.flatMap { view.hitTest($0.convert(point, from: nil)) }
            var target = deepest
            while let current = target, current !== view, !String(describing: type(of: current)).contains("HostingView") { target = current.superview }
            target?.mouseMoved(with: event)
            if !loggedTarget {
                loggedTarget = true
                let chain = sequence(first: deepest, next: { $0?.superview }).prefix(12).compactMap { $0.map { "\(type(of: $0))" } }.joined(separator: " < ")
                Log.write("[capture] 鼠标停在 \(point)，事件发给 \(target.map { "\(type(of: $0))" } ?? "无")；那一点上的视图：\(chain)")
            }
        }
        let startCPU = cpu(), start = CACurrentMediaTime()
        for index in 0...frames {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) / 60) {
                MainActor.assumeIsolated {
                    let t = index <= half ? Double(index) / Double(half) : Double(frames - index) / Double(frames - half)
                    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: top + (bottom - top) * t))
                    view.reflectScrolledClipView(clip)
                    moveMouse()
                    if index == half { Log.write("[capture] 侧栏滚到 y=\(Int(clip.bounds.origin.y))") }
                    if index == frames {
                        Log.write(String(format: "[capture] 侧栏逐帧滚动 %d 帧：用时 %.0f 毫秒，CPU %.0f 毫秒，可见区域 y=%d",
                                         frames, (CACurrentMediaTime() - start) * 1000, cpu() - startCPU, Int(clip.bounds.origin.y)))
                    }
                }
            }
        }
    }
}

/// cpumark 步骤上次记的进程 CPU 时间（毫秒）
@MainActor
private enum CPUMark {
    static var last: Double?
}

/// 自测用的主窗口副本：一直待在屏幕外（带标题栏的窗口默认会被挪回屏幕里）
private final class OffscreenPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// 自测量卡顿：主线程一轮（从被唤醒到再次空闲）超过 30 毫秒就记下来，按步骤汇总
@MainActor
enum MainBusy {
    static var step = ""
    private static var observer: CFRunLoopObserver?
    private static var spans: [(String, Double)] = []

    static func start() {
        guard observer == nil else { return }
        var woke: CFTimeInterval = 0
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                                                          true, Int.max) { _, activity in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                if activity == .afterWaiting { woke = now; return }
                guard woke > 0 else { return }
                let ms = (now - woke) * 1000
                if ms > 30 { spans.append((step, ms)); Log.write(String(format: "[capture] 主线程忙 %.0f 毫秒（%@）", ms, step)) }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    static func report() {
        var byStep: [String: [Double]] = [:]
        for (step, ms) in spans { byStep[step, default: []].append(ms) }
        for (step, list) in byStep.sorted(by: { $0.value.reduce(0, +) > $1.value.reduce(0, +) }) {
            Log.write(String(format: "[capture] 卡顿汇总 %@：%d 次，最长 %.0f 毫秒，合计 %.0f 毫秒", step, list.count, list.max() ?? 0, list.reduce(0, +)))
        }
        spans.removeAll()
    }
}
