import AVFoundation
import Network
import Observation
import Photos
import SwiftUI
import UserNotifications

/// App 用到的系统权限
enum PermissionKind: String, CaseIterable, Identifiable {
    case localNetwork, camera, notifications, microphone, photos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localNetwork: return L("本地网络")
        case .camera: return L("相机")
        case .notifications: return L("通知")
        case .microphone: return L("麦克风")
        case .photos: return L("相册")
        }
    }

    var symbol: String {
        switch self {
        case .localNetwork: return "wifi"
        case .camera: return "qrcode.viewfinder"
        case .notifications: return "bell.badge.fill"
        case .microphone: return "mic.fill"
        case .photos: return "photo.on.rectangle"
        }
    }

    /// 用来干什么（引导页和设置里都用这句）
    var purpose: String {
        switch self {
        case .localNetwork: return L("首次配对及处于同一 Wi-Fi 时，手机将直接连接电脑，速度最快。未授权将无法与电脑配对。")
        case .camera: return L("用于扫描电脑上的配对二维码。也可不使用相机，改为输入配对码。")
        case .notifications: return L("Agent 需要确认、完成任务或出错停止时，在锁屏上提醒你。")
        case .microphone: return L("按住说话，松开后由电脑转为文字并发送给 Agent。")
        case .photos: return L("将 Agent 发来的截图存储到相册。")
        }
    }

    /// 必须给的：不给 App 用不了
    var required: Bool { self == .localNetwork }

    /// 系统弹框的样子：标题、同意按钮叫什么
    var systemTitle: String {
        switch self {
        case .localNetwork: return L("“Kiteline”想要查找并连接到本地网络上的设备")
        case .camera: return L("“Kiteline”想要访问你的相机")
        case .notifications: return L("“Kiteline”想给你发送通知")
        case .microphone: return L("“Kiteline”想要访问麦克风")
        case .photos: return L("“Kiteline”想要添加到你的照片")
        }
    }

    var allowLabel: String {
        switch self {
        case .localNetwork, .notifications: return L("允许")
        case .camera, .microphone, .photos: return L("好")
        }
    }

    var usage: String {
        switch self {
        case .localNetwork: return L("连接电脑上的 Kiteline，以查看和回复编程会话。")
        case .camera: return L("用于扫描电脑上的配对二维码，或拍摄照片发送给 Agent。")
        case .notifications: return L("提醒可能包括提示、声音和图标标记。")
        case .microphone: return L("用于录制语音并发送给 Agent。")
        case .photos: return L("将 Agent 发来的截图存储到相册。")
        }
    }
}

enum PermissionState: Equatable {
    /// 还没问过（系统弹框还没出现过）
    case notAsked
    case granted
    case denied
}

/// 查、要系统权限；被拒的引导去「设置」打开
@MainActor
@Observable
final class Permissions {
    static let shared = Permissions()

    private(set) var states: [PermissionKind: PermissionState] = [:]
    /// 用到某个功能时发现没权限：弹框引导去设置
    var blocked: PermissionKind?

    private let probe = LocalNetworkProbe()
    private let defaults = UserDefaults.standard

    private init() {
        for kind in PermissionKind.allCases { states[kind] = .notAsked }
        if let saved = defaults.string(forKey: "localNetworkState") {
            states[.localNetwork] = saved == "granted" ? .granted : .denied
        }
    }

    func state(_ kind: PermissionKind) -> PermissionState { states[kind] ?? .notAsked }

    /// 从「设置」回来、回到前台时重新查一遍
    func refresh() async {
        states[.camera] = Self.map(AVCaptureDevice.authorizationStatus(for: .video))
        states[.microphone] = Self.map(AVAudioApplication.shared.recordPermission)
        states[.notifications] = Self.map(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
        states[.photos] = Self.map(PHPhotoLibrary.authorizationStatus(for: .addOnly))
        // 本地网络没有查询接口：问过一次以后才去探（没问过就探会直接弹系统框）
        if defaults.string(forKey: "localNetworkState") != nil {
            setLocalNetwork(await probe.check(waitForPrompt: false))
        }
        #if SNAPSHOT
        // 截图构建：假装某几项被拒绝过（TARS_DEMO_DENIED=localNetwork,microphone）
        for name in (ProcessInfo.processInfo.environment["TARS_DEMO_DENIED"] ?? "").split(separator: ",") {
            if let kind = PermissionKind(rawValue: String(name)) { states[kind] = .denied }
        }
        #endif
    }

    /// 弹系统授权框（已经拒绝过的不会再弹，只能去设置）
    @discardableResult
    func request(_ kind: PermissionKind) async -> PermissionState {
        switch kind {
        case .localNetwork:
            setLocalNetwork(await probe.check(waitForPrompt: true))
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
            states[.camera] = Self.map(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone:
            _ = await AVAudioApplication.requestRecordPermission()
            states[.microphone] = Self.map(AVAudioApplication.shared.recordPermission)
        case .notifications:
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            states[.notifications] = Self.map(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
            #if !KITELINE_MAC
            if states[.notifications] == .granted { PushSetup.shared.authorized() }
            #endif
        case .photos:
            states[.photos] = Self.map(await PHPhotoLibrary.requestAuthorization(for: .addOnly))
        }
        return state(kind)
    }

    /// 用某个功能前：有权限直接用；没问过就先问；拒绝过就弹引导
    func ensure(_ kind: PermissionKind) async -> Bool {
        switch state(kind) {
        case .granted: return true
        case .notAsked: return await request(kind) == .granted
        case .denied:
            blocked = kind
            return false
        }
    }

    /// 打开系统「设置」里 Kiteline 自己的那一页（本地网络、相机、麦克风、通知的开关都在这）
    func openSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #endif
    }

    private func setLocalNetwork(_ granted: Bool) {
        states[.localNetwork] = granted ? .granted : .denied
        defaults.set(granted ? "granted" : "denied", forKey: "localNetworkState")
    }

    private static func map(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    private static func map(_ status: AVAudioApplication.recordPermission) -> PermissionState {
        switch status {
        case .granted: return .granted
        case .undetermined: return .notAsked
        default: return .denied
        }
    }

    private static func map(_ status: UNAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized, .provisional, .ephemeral: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    private static func map(_ status: PHAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized, .limited: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }
}

/// 本地网络权限：iOS 没给查询接口，只能试——在局域网上登记一个 Bonjour 服务再找它，
/// 登记上了或找得到自己就是允许了，否则就是没允许。
/// 第一次试会弹系统框，要等用户点完（App 回到前台）再下结论。
@MainActor
final class LocalNetworkProbe {
    private static let serviceType = "_tars._tcp"

    func check(waitForPrompt: Bool) async -> Bool {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let listener = try? NWListener(using: parameters)
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)
        let result = Signal()
        listener?.service = NWListener.Service(name: "tars-probe-\(UUID().uuidString.prefix(8))", type: Self.serviceType)
        listener?.newConnectionHandler = { $0.cancel() }
        listener?.serviceRegistrationUpdateHandler = { change in
            if case .add = change { result.send(true) }
        }
        browser.browseResultsChangedHandler = { results, _ in
            if !results.isEmpty { result.send(true) }
        }
        listener?.start(queue: .main)
        browser.start(queue: .main)
        defer {
            listener?.cancel()
            browser.cancel()
        }

        #if os(iOS)
        if waitForPrompt {
            // 系统框弹出时 App 会失去前台；等用户点完回到前台。3 秒都没弹框说明以前就选过了
            let start = Date()
            var sawPrompt = false
            while Date().timeIntervalSince(start) < 60 {
                if result.granted { return true }
                if UIApplication.shared.applicationState != .active {
                    sawPrompt = true
                } else if sawPrompt || Date().timeIntervalSince(start) > 3 {
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        #endif
        // 再给 2 秒让 Bonjour 登记 / 找到自己
        for _ in 0..<20 {
            if result.granted { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return result.granted
    }

    /// 回调都在主队列上
    private final class Signal: @unchecked Sendable {
        var granted = false
        func send(_ ok: Bool) { if ok { granted = true } }
    }
}
