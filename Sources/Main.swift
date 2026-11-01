import AppKit
import KitelineKit

/// 程序入口。用 @main + -parse-as-library 编译，避免顶层代码与多文件编译冲突。
///
/// 支持的自检参数（面向开发与排障，不写在用户文档里当日常用法）：
///   --render <界面> <png> [--dark]  把界面离屏渲染成图片，方便核对
///   --drill-notify          灌入合成事件，验证提醒链路
///   --show-panel            启动后立刻展开面板（用于人工确认界面）
@main
enum CCPulseMain {
    static func main() {
        let args = CommandLine.arguments
        // watcher 退出、手机断线时往管道/套接字写会触发 SIGPIPE，默认会直接杀掉进程
        signal(SIGPIPE, SIG_IGN)
        // 隔离的测试实例：界面语言用自己那份、每次从「跟随系统」开始（不然跟着正式版里用户选的语言走，测试结果看用户当时的设置）；
        // 截图要英文就带 TARS_LANG=en
        if AppConfig.isolated {
            let store = UserDefaults(suiteName: "com.mrhong.tars.test-instance.lang") ?? .standard
            store.removeObject(forKey: "appLanguage")
            if let lang = ProcessInfo.processInfo.environment["TARS_LANG"] { store.set(lang, forKey: "appLanguage") }
            Lang.store = store
        }

        // 命令行模式（不进 GUI）：来源管理、帮助
        if args.count > 1, args[1] == "sources" {
            exit(SourceCLI.run(arguments: Array(args.dropFirst(2))))
        }
        // 推送加密自检：输出加密结果与 VAPID 头，供外部用标准实现解密核对
        if args.count == 6, args[1] == "webpush-selftest" {
            let push = WebPush()
            guard let p256dh = WebPush.decodeBase64URL(args[2]), let auth = WebPush.decodeBase64URL(args[3]),
                  let body = try? WebPush.encrypt(payload: Data(args[4].utf8), p256dh: p256dh, auth: auth),
                  let url = URL(string: args[5]),
                  let authorization = try? push.vapidAuthorization(for: url) else {
                print("{\"ok\":false}"); exit(1)
            }
            print("{\"ok\":true,\"body\":\"\(WebPush.base64URL(body))\",\"authorization\":\"\(authorization)\",\"publicKey\":\"\(push.publicKey)\"}")
            exit(0)
        }
        if args.contains("--help") || args.contains("-h") {
            SourceCLI.run(arguments: ["help"])
            print("""

            其他参数（开发/自检用）：
              --render <界面> <png> [--dark]  把界面离屏渲染成图片（menubar/main/general/phone/watch/sources/permissions/about）
              --background             只待在菜单栏，不打开主窗口
              --drill-notify           灌入合成事件验证提醒链路
              --show-panel             启动后直接展开面板
              --selftest-exit <秒>     运行指定秒数后退出
            """)
            exit(0)
        }

        // 离屏渲染界面：--render <menubar|main|general|phone|sources|permissions|about> <png> [--dark]
        if let index = args.firstIndex(of: "--render"), index + 2 < args.count {
            SelfTest.render(args[index + 1], to: args[index + 2], dark: args.contains("--dark"))
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)

        // 自检开关：命令行参数，或 -drillNotify YES / -showPanel YES
        if args.contains("--drill-notify") || UserDefaults.standard.bool(forKey: "drillNotify") {
            delegate.drillNotificationsOnLaunch = true
            Log.write("已启用提醒自检")
        }
        if args.contains("--show-panel") || UserDefaults.standard.bool(forKey: "showPanel") {
            delegate.showPanelOnLaunch = true
        }
        // 开机自启 / 测试：只待在菜单栏，不打开主窗口
        if args.contains("--background") || args.contains("--selftest-exit") {
            delegate.startInBackground = true
        }
        // 集成自检用：跑一段时间后自行退出，便于脚本断言日志
        if let index = args.firstIndex(of: "--selftest-exit"), index + 1 < args.count,
           let seconds = Double(args[index + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                Log.write("自检计时结束，退出")
                AppState.shared.shutdown()
                Log.flush()   // 异步日志要先落盘，否则自检读不到
                exit(0)
            }
        }

        app.run()
    }
}
