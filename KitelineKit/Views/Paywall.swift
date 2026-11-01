import StoreKit
import SwiftUI

/// 付费页：不在电脑所在的 Wi-Fi 时想连（远程访问），或在设置里点「Kiteline Pro」，从底部弹出来
struct PaywallView: View {
    @PanelDismiss private var dismiss
    @Environment(\.openURL) private var openURL
    let reason: Store.Reason
    @State private var selected: String?
    private var store: Store { Store.shared }

    var body: some View {
        let plans = Plan.list(store.products)
        let plan = plans.first { $0.id == selected } ?? plans.first { $0.yearly } ?? plans.first
        ScrollView {
            VStack(spacing: 22) {
                header
                features
                costNote
                VStack(spacing: 10) {
                    if plans.isEmpty {
                        if store.loadingProducts { ProgressView().padding(.vertical, 30) } else {
                            Button("订阅信息加载失败，轻点重试") { Task { await store.loadProducts() } }
                                .font(.ui(.subheadline)).padding(.vertical, 24)
                        }
                    }
                    ForEach(plans) { option in planCard(option, on: option.id == plan?.id) }
                }
                if let plan { buyButton(plan) }
                if let message = store.message {
                    Text(message).font(.ui(.footnote)).foregroundStyle(Theme.removed).multilineTextAlignment(.center)
                }
                finePrint(plan)
            }
            .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.pageBackground)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 30, height: 30).background(Color.primary.opacity(0.08), in: Circle())
                    // 圆只有 30 点：点的范围放大到 44（圆画的位置不变）
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("关闭")
            .padding(7)
        }
        .presentationDragIndicator(.visible)
        .task { if store.products.isEmpty { await store.loadProducts() } }
        .onChange(of: store.isPro) { _, pro in if pro { dismiss() } }
    }

    private var header: some View {
        VStack(spacing: 10) {
            KiteMark(color: Theme.claude).frame(width: 64, height: 64)
            Text("Kiteline Pro").font(.ui(.largeTitle).weight(.bold))
            Text(subtitle).font(.ui(.subheadline)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private var subtitle: String {
        switch reason {
        case .remote: return L("在电脑所在的 Wi-Fi 中，全部功能免费使用。\n订阅后可通过 5G 或其他 Wi-Fi 远程连接。")
        case .settings: return L("离开电脑所在的 Wi-Fi，也能随时连接你的 Agent")
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 14) {
            feature("antenna.radiowaves.left.and.right", L("随时随地访问"), L("通过 5G 或其他 Wi-Fi 连接电脑，端到端加密"))
            feature("arrow.triangle.2.circlepath", L("切换网络不断线"), L("在 Wi-Fi 与移动网络之间切换时，连接自动保持"))
            feature("checkmark.shield", L("在外也能及时处理"), L("Agent 请求确认或提出问题时，随时授权与回复"))
            feature("applewatch", L("手表同样可用"), L("离开电脑所在的 Wi-Fi，也能抬腕处理"))
            feature("wifi", L("同一 Wi-Fi 下免费"), L("在电脑所在的 Wi-Fi 中，所有功能均可免费使用"))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// 为什么要订阅：远程访问走中继服务器，有服务器和流量成本（10-29 起在付费页说明，请用户理解）
    private var costNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "server.rack").font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 1)
            Text("远程访问需要经由中继服务器转发和协助直连，服务器与流量会持续产生费用。订阅收入用于维持这些服务稳定运行，感谢你的理解与支持。")
                .font(.ui(.caption)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.claude).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(.subheadline).weight(.semibold))
                Text(detail).font(.ui(.caption)).foregroundStyle(.secondary)
            }
        }
    }

    private func planCard(_ plan: Plan, on: Bool) -> some View {
        Button { selected = plan.id } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20)).foregroundStyle(on ? Theme.claude : Color.secondary.opacity(0.5))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(plan.title).font(.ui(.body).weight(.semibold))
                        if let badge = plan.badge {
                            Text(badge).font(.ui(.caption2).weight(.bold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.claude, in: Capsule())
                        }
                    }
                    if let note = plan.note { Text(note).font(.ui(.caption)).foregroundStyle(.secondary) }
                }
                Spacer()
                Text(plan.price + plan.unit).font(.ui(.body).weight(.semibold).monospacedDigit())
            }
            .foregroundStyle(.primary)
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(on ? Theme.claude : .clear, lineWidth: 1.5))
        }
        .buttonStyle(PressableStyle())
    }

    private func buyButton(_ plan: Plan) -> some View {
        let trial = store.trialEligible ? plan.trialDays : nil
        return Button {
            guard let product = plan.product else { return }
            Task { await store.buy(product) }
        } label: {
            ZStack {
                if store.purchasing == plan.id {
                    ProgressView().tint(.white)
                } else {
                    Text(trial.map { "免费试用 \($0) 天" } ?? "订阅").font(.ui(.headline))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity).frame(height: 52)
            .background(Theme.claude, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .disabled(store.purchasing != nil || plan.product == nil)
    }

    private func finePrint(_ plan: Plan?) -> some View {
        VStack(spacing: 12) {
            if let plan {
                let trial = store.trialEligible ? plan.trialDays : nil
                Text((trial.map { L("试用 %@ 天结束后，", "\($0)") } ?? "") + L("按 %@%@ 自动续期。", "\(plan.price)", "\(plan.unit)")
                     + L("可随时在 iPhone「设置 → Apple 账户 → 订阅」中取消。在当前订阅期结束前至少 24 小时取消，将不会自动续订。"))
                    .font(.ui(.caption2)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 18) {
                footerLink(L("恢复购买")) { Task { await store.restore() } }
                footerLink(L("使用条款")) { openURL(Store.termsURL) }
                footerLink(L("隐私政策")) { openURL(Store.privacyURL) }
            }
            .font(.ui(.footnote))
            .foregroundStyle(.secondary)
            .padding(.vertical, -10)   // 点击区域上下各扩了 10，排版上收回来
        }
    }

    /// 底部的小字链接：字只有 footnote 那么高，点击区域上下各扩 10 点
    private func footerLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).padding(.vertical, 10).contentShape(Rectangle())
        }
        .buttonStyle(.steady(.plain))
    }
}

/// 付费页上的一档（月度 / 年度）。截图版拿不到 App Store 的商品，用假的
struct Plan: Identifiable {
    var id: String
    var title: String
    var price: String
    var unit: String
    var note: String?
    var badge: String?
    var yearly: Bool
    var trialDays: Int?
    var product: Product?

    static func list(_ products: [Product]) -> [Plan] {
        #if SNAPSHOT
        if products.isEmpty {
            // 截图用：和 App Store Connect 里定的价格一致（10-29 降价：月付 ¥14、年付 ¥98，不设免费试用）
            return [Plan(id: "m", title: L("月度"), price: "¥14", unit: L("/月"), note: nil, badge: nil, yearly: false, trialDays: nil),
                    Plan(id: "y", title: L("年度"), price: "¥98", unit: L("/年"), note: L("约 ¥8.17/月"), badge: L("省 42%"), yearly: true, trialDays: nil)]
        }
        #endif
        let monthly = products.first { $0.subscription?.subscriptionPeriod.unit == .month }
        return products.map { product in
            let period = product.subscription?.subscriptionPeriod
            let yearly = period?.unit == .year
            var note: String?
            var badge: String?
            if yearly {
                note = L("约 ") + (product.price / 12).formatted(product.priceFormatStyle) + L("/月")
                if let monthly, monthly.price > 0 {
                    let save = 1 - NSDecimalNumber(decimal: product.price / 12 / monthly.price).doubleValue
                    if save >= 0.05 { badge = L("省 %@%%", "\(Int((save * 100).rounded()))") }
                }
            }
            var trial: Int?
            if let offer = product.subscription?.introductoryOffer, offer.paymentMode == .freeTrial {
                let p = offer.period
                trial = p.unit == .day ? p.value : (p.unit == .week ? p.value * 7 : (p.unit == .month ? p.value * 30 : nil))
            }
            return Plan(id: product.id, title: yearly ? L("年度") : L("月度"), price: product.displayPrice, unit: yearly ? L("/年") : L("/月"),
                        note: note, badge: badge, yearly: yearly, trialDays: trial, product: product)
        }
    }
}

/// 在这里弹付费页：主界面挂一个；本身就是弹窗的页面（设置、新建任务）各挂一个——弹窗开着时主界面弹不出别的弹窗
struct PaywallHost: ViewModifier {
    func body(content: Content) -> some View {
        content.sheetPanel(isPresented: Binding(get: { Store.shared.paywall != nil }, set: { if !$0 { Store.shared.paywall = nil } })) {
            PaywallView(reason: Store.shared.paywall ?? .settings)
        }
    }
}

extension View {
    func paywallHost() -> some View { modifier(PaywallHost()) }
}

