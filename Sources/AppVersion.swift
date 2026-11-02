import Foundation

/// App 与打包资源的版本信息。
///
/// watcherScriptVersion 必须与 watcher/kiteline-watch.py 里的 WATCHER_VERSION 保持一致，
/// 构建脚本会在编译时校验；不一致就无法判断远端/本机脚本是否需要更新。
enum AppVersion {
    /// App 版本只认 Info.plist（CFBundleShortVersionString）：以前这里另写一份，改版本时漏改，「关于」页和手机上显示的版本落后一版
    static let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    static let watcherScriptVersion = "2.31.0"
}
