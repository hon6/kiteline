import Foundation

/// 给各家编程 agent 装技能：截图（screenshots）、网页测试报告（playwright）、待办与关键信息（todos）、任务阶段（stages）。
///
/// 技能正文和装到哪由 watcher 管（watcher/kiteline-watch.py 的 SKILLS_BUILTIN，是一份 JSON 数据，可经插件索引下发新版）：
/// 每台电脑上的 watcher 自己装到这台电脑上各家 agent 的技能目录（Claude Code、Codex、DeepSeek Harness、Qwen Code；
/// OpenCode 读 Claude 的那份），带版本标记，关掉的按标记删。
/// 这里只把设置里哪几个开着经环境变量 CCPULSE_SKILLS 带给 watcher（本机、远端都是）；开关一变，让在线的 watcher 当场照着装 / 删。
enum AgentSkill {
    /// 由 AppState 按配置设置；来源对象拿不到完整配置，用这几个开关传进来
    static var enabled = true { didSet { if enabled != oldValue { syncLive() } } }
    static var testEnabled = true { didSet { if testEnabled != oldValue { syncLive() } } }
    static var todoEnabled = true { didSet { if todoEnabled != oldValue { syncLive() } } }
    static var stageEnabled = true { didSet { if stageEnabled != oldValue { syncLive() } } }
    /// 给 OpenCode 装 Kiteline 插件（watcher 来装，见 ccpulse-watch.py 的 install_opencode_plugin）：同样由 AppState 按配置设置
    static var openCodePlugin = true

    /// 开着的技能（id 同 watcher 的技能数据）
    static var skillIds: [String] {
        (enabled ? ["screenshots"] : []) + (testEnabled ? ["playwright"] : []) + (todoEnabled ? ["todos"] : []) + (stageEnabled ? ["stages"] : [])
    }

    /// 启动 watcher 时带的环境变量：哪些技能开着；OpenCode 插件关掉了就让它删掉装过的
    static var watcherEnvironment: [String: String] {
        // 设置 → 插件里关掉的插件也随环境变量带过去（本机、远端都走这里）
        var env = (openCodePlugin ? [:] : ["CCPULSE_OPENCODE_PLUGIN": "0"]).merging(PluginStore.shared.watcherEnvironment) { _, new in new }
        if manages { env["CCPULSE_SKILLS"] = skillIds.joined(separator: ",") }
        return env
    }

    /// 隔离的测试实例不动这台电脑真的技能目录（不带 CCPULSE_SKILLS 的 watcher 不装也不删）；测技能本身时用 KITELINE_SKILL_TEST=1 放开
    private static var manages: Bool {
        !AppConfig.isolated || ProcessInfo.processInfo.environment["KITELINE_SKILL_TEST"] == "1"
    }

    /// 在线的 watcher 马上照新开关装 / 删（不在线的下次连上时按环境变量来）。AppState 初始化时也会走到这里，所以放到下一轮再取
    private static func syncLive() {
        guard manages else { return }
        DispatchQueue.main.async {
            for source in AppState.shared.liveSources {
                source.request(["cmd": "skills", "enabled": skillIds], timeout: 20) { result in
                    if case .failure(let error) = result { Log.write("[\(source.config.displayName)] 同步技能失败：\(error)") }
                }
            }
        }
    }
}
