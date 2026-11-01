import Foundation
import Observation
import StoreKit

/// 订阅（Kiteline Pro，StoreKit 2）。Mac 端不做任何限制，只在手机上分（10-29）：
/// - 免费版：在电脑所在的 Wi-Fi（局域网）里全部功能都能用——看、回复、语音、发图、点允许、新建任务……
/// - 订阅后：不在同一个 Wi-Fi 也能连（远程访问：点对点 / 中继 / Tailscale）。不设免费试用：局域网本来就免费（10-29）
@MainActor
@Observable
final class Store {
    static let shared = Store()

    /// App Store Connect 里建的订阅（同一个订阅组「Kiteline Pro」）
    static let productIds = ["com.mrhong.tars.pro.monthly", "com.mrhong.tars.pro.yearly"]
    /// 使用条款：自己的页面（订阅说明 + 免责），里面引用苹果的标准许可协议（EULA）；页面在 relay/site/，用 relay/site.sh 发布
    static var termsURL: URL { Lang.site("terms") }   // 英文界面跳到页面里的英文部分
    static var privacyURL: URL { Lang.site("privacy") }   // 英文界面跳到页面里的英文部分
    static var supportURL: URL { Lang.site("support") }   // 英文界面跳到页面里的英文部分

    enum Reason { case remote, settings }

    private(set) var products: [Product] = []
    /// App Store 里确实买了、还在有效期
    private(set) var entitled = false
    private(set) var loadingProducts = false
    private(set) var purchasing: String?
    /// 首次免费试用还能不能用（每个 Apple ID 只有一次）
    private(set) var trialEligible = true
    var message: String?
    /// 付费页开着，以及为什么弹的
    var paywall: Reason?

    /// 开发版（Xcode 装的）默认全部放开，免得还没在 App Store Connect 建好商品就把自己锁住；
    /// 设置里打开「模拟免费版」才按真的订阅状态来
    #if DEBUG
    var simulateFree = UserDefaults.standard.bool(forKey: "simulateFree") {
        didSet { UserDefaults.standard.set(simulateFree, forKey: "simulateFree"); publish() }
    }
    #endif

    /// 订阅了（或开发版没开「模拟免费版」）
    var isPro: Bool {
        #if KITELINE_MAC
        return true   // Mac 端不做任何限制
        #else
        // 演示模式：所有功能都能试（不连 Mac，不涉及真的操作）
        if Demo.active { return true }
        #if SNAPSHOT
        return ProcessInfo.processInfo.environment["TARS_DEMO_FREE"] == nil
        #elseif DEBUG
        return !simulateFree || entitled
        #else
        return entitled
        #endif
        #endif
    }

    private var updates: Task<Void, Never>?

    func start() {
        publish()
        guard updates == nil else { return }
        updates = Task.detached { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
                await self?.refresh()
            }
        }
        Task {
            await refresh()
            await loadProducts()
        }
    }

    func loadProducts() async {
        guard !loadingProducts else { return }
        loadingProducts = true
        defer { loadingProducts = false }
        do {
            products = try await Product.products(for: Self.productIds).sorted { $0.price < $1.price }
            if let first = products.first { trialEligible = await first.subscription?.isEligibleForIntroOffer ?? false }
        } catch {
            message = L("订阅信息加载失败：%@", "\(error.localizedDescription)")
        }
    }

    /// 重新看一遍现在有没有有效订阅（启动、买完、恢复购买、续费 / 退款通知来了）
    func refresh() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, Self.productIds.contains(transaction.productID), transaction.revocationDate == nil {
                active = true
            }
        }
        entitled = active
        publish()
        ProGate.markChecked()
        if isPro { paywall = nil }
    }

    func buy(_ product: Product) async {
        purchasing = product.id
        message = nil
        defer { purchasing = nil }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    message = L("此次购买未通过 App Store 验证，请稍后轻点「恢复购买」")
                    return
                }
                await transaction.finish()
                await refresh()
            case .pending:
                message = L("等待批准后生效（例如家人共享中需家长同意）")
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = L("购买失败：%@", "\(error.localizedDescription)")
        }
    }

    func restore() async {
        message = nil
        do {
            try await AppStore.sync()
            await refresh()
            if !entitled { message = L("此 Apple 账户暂无有效的 Kiteline Pro 订阅") }
        } catch {
            message = L("恢复购买失败：%@", "\(error.localizedDescription)")
        }
    }

    @ObservationIgnored private var published: Bool?

    /// 进出演示模式：订阅状态跟着变（演示里全部放开）
    func demoChanged() { publish() }

    /// 告诉网络层现在有没有订阅（网络层不在主线程，读不了这里）；变了就通知（开 / 关远程访问）
    private func publish() {
        let now = isPro
        ProGate.set(now)
        if let published, published != now { NotificationCenter.default.post(name: .tarsProChanged, object: nil) }
        published = now
    }
}

/// 网络层用的远程访问开关（网络层不在主线程，读不了 Store）：没订阅时只走局域网，不走点对点、中继和 Tailscale
enum ProGate {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var unlocked = true
    nonisolated(unsafe) private static var checked = false

    static var isUnlocked: Bool { lock.withLock { unlocked } }
    static func set(_ value: Bool) { lock.withLock { unlocked = value } }
    /// 订阅状态（报给电脑的使用统计）：启动后第一次查完订阅之前是 nil，免得报错
    static var reported: Bool? { lock.withLock { checked ? unlocked : nil } }
    static func markChecked() { lock.withLock { checked = true } }
}

extension AppModel {
    /// 远程访问是订阅功能：没订阅就弹付费页，返回 false
    func requirePro(_ reason: Store.Reason = .remote) -> Bool {
        if Store.shared.isPro { return true }
        Haptics.tap()
        Store.shared.paywall = reason
        return false
    }
}

extension Notification.Name {
    /// 订阅状态变了（买了、过期了、开发版切了「模拟免费版」）
    static let tarsProChanged = Notification.Name("tarsProChanged")
}
