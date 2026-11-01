#if !KITELINE_MAC
import Observation
import UIKit
import UserNotifications

/// 锁屏推送：App 不在前台时，「需要你确认」「有结论了」这些提醒照样推到锁屏（和手表上）。
///
/// 1. 允许了通知 → 向苹果要推送令牌（registerForRemoteNotifications）
/// 2. 连上 Mac → 订阅：POST /api/push/subscribe，地址 apns:<环境>:<推送令牌>，再带上 PushKeys 的公钥和 auth
/// 3. Mac 加密每条提醒交给 Kiteline 推送网关（tars.betac.cn/push），网关转苹果推送服务
/// 4. 通知扩展解密，换上真正的标题和内容；点开通知进对应的会话
///
/// App 开着时 Mac 不推锁屏（只在 App 里弹横幅，见 AppModel.startPresence），同一条不会两样都来
@MainActor
@Observable
final class PushSetup: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushSetup()

    /// 点了通知要打开的：会话 key 或页面（today / usage），MainView 看到就推进去；
    /// reconnect：长按通知点的「尝试重连」（电脑报来的提示 id），MainView 等连上电脑再去做
    struct Open: Equatable {
        var key: String?
        var route: String?
        var reconnect: String?
        let id = UUID()
    }
    /// 通知长按出来的按钮（通知扩展按推送内容挑类别）
    nonisolated static let reconnectCategory = "reconnect"
    nonisolated static let reconnectAction = "reconnect"
    var open: Open?

    @ObservationIgnored private var token: String?
    @ObservationIgnored private weak var model: AppModel?
    /// 报给了哪台 Mac（Mac 的设备令牌 + 订阅地址）、什么时候报的：一分钟内连上好几次（网络来回切）不重复报
    @ObservationIgnored private var subscribed: String?
    @ObservationIgnored private var subscribedAt = Date.distantPast
    /// 订阅时用的那条连接：断开配对时拿它去退订（那时 AppModel 可能已经没了）
    @ObservationIgnored private var subscribedVia: (api: MacAPI, endpoint: String)?

    /// App 一启动就调：接上通知回调，允许过通知的直接要推送令牌（令牌会变，苹果建议每次启动都要）
    func start() {
        UNUserNotificationCenter.current().delegate = self
        // 「VS Code 弹着对话框」「连接已断开」的通知长按有「尝试重连」：要打开 App（连电脑要靠 App）
        let reconnect = UNNotificationAction(identifier: Self.reconnectAction, title: L("尝试重连"), options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: Self.reconnectCategory, actions: [reconnect], intentIdentifiers: []),
        ])
        Task {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            if Self.allowed(status) { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    /// 刚允许了通知（引导页、就绪检查里点的）
    func authorized() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// 苹果给了推送令牌
    func received(token data: Data) {
        token = data.map { String(format: "%02x", $0) }.joined()
        if let api = model?.api { Task { await subscribe(api) } }
    }

    /// 连上 Mac 了：对一下订阅；通知被关了就退订（免得 Mac 以为推到了）
    func connected(_ model: AppModel) {
        self.model = model
        let api = model.api
        Task { await subscribe(api) }
    }

    private func subscribe(_ api: MacAPI) async {
        guard let token, !Demo.active else { return }
        let endpoint = "apns:\(Self.environment):\(token)"
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if !Self.allowed(status) {
            if subscribed?.hasSuffix(endpoint) == true {
                _ = try? await api.post("/api/push/unsubscribe", body: ["endpoint": endpoint])
                subscribed = nil
            }
            return
        }
        // 每次连上都对一下：Mac 那边的订阅可能被删过（推送失败、在 Mac 上清过），同一个订阅 Mac 收到会直接忽略
        let mark = api.token + "|" + endpoint
        guard subscribed != mark || Date().timeIntervalSince(subscribedAt) > 60 else { return }
        let keys = PushKeys.loadOrCreate()
        do {
            _ = try await api.post("/api/push/subscribe", body: [
                "endpoint": endpoint, "keys": ["p256dh": keys.p256dh, "auth": keys.authText], "label": Pairing.deviceName,
            ])
            subscribed = mark
            subscribedAt = Date()
            subscribedVia = (api, endpoint)
        } catch {
            // 下次连上再报
        }
    }

    /// 在手机上断开配对：先让 Mac 退订，不然断开以后那台 Mac 还会往这台手机推提醒
    func leave() {
        guard let via = subscribedVia else { return }
        subscribedVia = nil
        subscribed = nil
        Task { _ = try? await via.api.post("/api/push/unsubscribe", body: ["endpoint": via.endpoint]) }
    }

    private static func allowed(_ status: UNAuthorizationStatus) -> Bool {
        [.authorized, .provisional, .ephemeral].contains(status)
    }

    /// 推送环境：Xcode 直接装的开发版走苹果的沙盒推送，TestFlight / App Store 版走正式的。
    /// 看安装包里的描述文件：App Store 版没有描述文件，就是正式环境
    static let environment: String = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8)),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return "production" }
        return entitlements["aps-environment"] as? String == "development" ? "development" : "production"
    }()

    // MARK: 通知回调

    // 两个回调都用带完成回调的写法、回到主线程再调完成回调：用 async 写法时系统在后台线程收尾，
    // UIKit 在那里更新快照会断言失败、整个 App 退出（10-25 反馈：点推送打开就闪退，崩在 _updateSnapshotAndStateRestoration）

    /// App 在前台时来了推送：Mac 以为 App 不在前台（刚切回来、「我在前台」还没报上）才会推。
    /// 实时连接已经连上的话，同一条 App 里会弹横幅，系统通知就不弹了；没连上照常弹
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let live = UIApplication.shared.applicationState == .active && self.model?.connected == true
                completionHandler(live ? [] : [.banner, .list, .sound])
            }
        }
    }

    /// 点了通知：进对应的会话或页面
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let key = info["key"] as? String
        let route = info["route"] as? String
        let reconnect = response.actionIdentifier == Self.reconnectAction ? info["alert"] as? String : nil
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.open = Open(key: key, route: route, reconnect: reconnect)
                completionHandler()
            }
        }
    }
}

/// 推送令牌只能从 UIApplicationDelegate 拿
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PushSetup.shared.start()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushSetup.shared.received(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // 模拟器、没联网、描述文件里没有推送权限：锁屏推送用不了，App 里的横幅照常
    }

    /// 支持的方向：iPhone 照旧只竖屏，iPad 全部；iPhone Duo（有铰链）全部——内屏打开时是横着用的
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Hinge.orientations(for: window)
    }
}
#endif
