import SwiftUI

/// 界面从环境里拿 AppModel。原来是 @Environment(AppModel.self)（要 macOS 14 / iOS 17），
/// 现在用自己的环境键，macOS 12 也能用（见 KitelineKit/Shared/KitelineObservation.swift）：
///
///     @EnvModel private var model                                     // 一定有（没有就是代码写错了）
///     @Environment(\.appModelSlot) private var model: AppModel?       // 可能没有
///     .environment(\.appModelSlot, model)                             // 往下传
struct AppModelSlotKey: EnvironmentKey {
    static let defaultValue: AppModel? = nil
}

extension EnvironmentValues {
    var appModelSlot: AppModel? {
        get { self[AppModelSlotKey.self] }
        set { self[AppModelSlotKey.self] = newValue }
    }
}

@propertyWrapper
struct EnvModel: DynamicProperty {
    @Environment(\.appModelSlot) private var slot

    init() {}

    var wrappedValue: AppModel {
        guard let slot else { fatalError("界面没拿到 AppModel：上层要 .environment(\\.appModelSlot, model)") }
        return slot
    }
}
