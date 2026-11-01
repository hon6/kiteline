import CoreGraphics
import Foundation
import SwiftUI

/// 会话来自哪个编程 agent（Claude Code、Codex、Copilot……）：名字 + 单色标志。
/// 会话数据里的 agent 字段（电脑端给，没有就是 claude-code）对应这里的 id；列表「按 Agent」分组、会话标题前的小标志都查这张表。
/// 标志取自 LobeHub Icons 的单色版（MIT，github.com/lobehub/lobe-icons），24×24 画布的 SVG 路径原样收录，
/// 跟着文字颜色走、不用品牌色（界面少颜色）。名称和标志归各自所有者，只用来标明会话来自哪个工具。
/// iPhone、手表、Mac（build.sh 编进 KitelineKit）共用这一份；加一个 agent 就在 all 里加一行
public struct AgentInfo: Identifiable, Sendable {
    public let id: String
    public let name: String
    /// 每层一条 SVG 路径（奇偶填充）和这一层的不透明度；没有标志的显示名字首字母
    let layers: [(d: String, opacity: Double)]
    /// 插件给的称呼（电脑端 /api/state 的 agents）
    var spoken: String? = nil

    /// 对话里怎么称呼它：「Claude 想使用 Bash」「中断 Codex」（Claude Code 叫 Claude，Gemini CLI 叫 Gemini……）
    public var speaker: String {
        spoken ?? ["claude-code": "Claude", "copilot": "Copilot", "gemini-cli": "Gemini", "qwen-code": "Qwen", "kimi-cli": "Kimi",
                   "deepseek-harness": "DeepSeek"][id] ?? name
    }

    /// 确认卡片要不要给「允许，且本会话不再询问」：DeepSeek Harness 的审批只有「允许这一次」
    public var allowsAlways: Bool { id != "deepseek-harness" }

    /// 标志的路径（24×24，奇偶填充）：交给世界模式的网页自己画（机房的标志牌、小人胸前的印花）
    public var markPaths: [(d: String, opacity: Double)] { layers }
}

public enum Agents {
    /// 没标 agent 的会话（老版本电脑端、现在的 watcher 只认 Claude Code）都算 Claude Code
    public static let defaultID = "claude-code"

    public static func info(_ id: String?) -> AgentInfo {
        let key = id.flatMap { $0.isEmpty ? nil : $0 } ?? defaultID
        return byID[key] ?? extra.info(key) ?? AgentInfo(id: key, name: key, layers: [])
    }

    /// 电脑端插件给的 agent（/api/state 的 agents）：名称、标志只补内置表里没有的，新 agent 不用为了标志发 App；
    /// 要求的最低 iPhone 版本内置的也记（某家 agent 的新插件用到了这个版本还不认的东西）
    public static func register(_ cards: [AgentProfile]) {
        extra.set(cards.filter { !$0.id.isEmpty && !$0.name.isEmpty && byID[$0.id] == nil },
                  minimums: Dictionary(cards.compactMap { card in card.minIOS.map { (card.id, $0) } }, uniquingKeysWith: { _, last in last }))
    }

    /// 电脑上这家 agent 的插件要求的最低 iPhone 版本（插件清单的 minApp.ios）；没要求为 nil
    public static func requiredAppVersion(_ id: String) -> String? { extra.minimum(id) }

    fileprivate static let extra = Registered()

    private static let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    /// 解析好的路径（24×24），按路径字符串缓存：标志每次重绘只做一次缩放
    fileprivate static let paths: [String: CGPath] = Dictionary(
        all.flatMap { $0.layers.map { ($0.d, SVGPath.parse($0.d)) } }, uniquingKeysWith: { first, _ in first })

    public static let all: [AgentInfo] = [
        AgentInfo(id: "claude-code", name: "Claude Code", layers: [
            ("M20.998 10.949H24v3.102h-3v3.028h-1.487V20H18v-2.921h-1.487V20H15v-2.921H9V20H7.488v-2.921H6V20H4.487v-2.921H3V14.05H0V10.95h3V5h17.998v5.949zM6 10.949h1.488V8.102H6v2.847zm10.51 0H18V8.102h-1.49v2.847z", 1),
        ]),
        AgentInfo(id: "codex", name: "Codex", layers: [
            ("M8.086.457a6.105 6.105 0 013.046-.415c1.333.153 2.521.72 3.564 1.7a.117.117 0 00.107.029c1.408-.346 2.762-.224 4.061.366l.063.03.154.076c1.357.703 2.33 1.77 2.918 3.198.278.679.418 1.388.421 2.126a5.655 5.655 0 01-.18 1.631.167.167 0 00.04.155 5.982 5.982 0 011.578 2.891c.385 1.901-.01 3.615-1.183 5.14l-.182.22a6.063 6.063 0 01-2.934 1.851.162.162 0 00-.108.102c-.255.736-.511 1.364-.987 1.992-1.199 1.582-2.962 2.462-4.948 2.451-1.583-.008-2.986-.587-4.21-1.736a.145.145 0 00-.14-.032c-.518.167-1.04.191-1.604.185a5.924 5.924 0 01-2.595-.622 6.058 6.058 0 01-2.146-1.781c-.203-.269-.404-.522-.551-.821a7.74 7.74 0 01-.495-1.283 6.11 6.11 0 01-.017-3.064.166.166 0 00.008-.074.115.115 0 00-.037-.064 5.958 5.958 0 01-1.38-2.202 5.196 5.196 0 01-.333-1.589 6.915 6.915 0 01.188-2.132c.45-1.484 1.309-2.648 2.577-3.493.282-.188.55-.334.802-.438.286-.12.573-.22.861-.304a.129.129 0 00.087-.087A6.016 6.016 0 015.635 2.31C6.315 1.464 7.132.846 8.086.457zm-.804 7.85a.848.848 0 00-1.473.842l1.694 2.965-1.688 2.848a.849.849 0 001.46.864l1.94-3.272a.849.849 0 00.007-.854l-1.94-3.393zm5.446 6.24a.849.849 0 000 1.695h4.848a.849.849 0 000-1.696h-4.848z", 1),
        ]),
        AgentInfo(id: "copilot", name: "GitHub Copilot", layers: [
            ("M19.245 5.364c1.322 1.36 1.877 3.216 2.11 5.817.622 0 1.2.135 1.592.654l.73.964c.21.278.323.61.323.955v2.62c0 .339-.173.669-.453.868C20.239 19.602 16.157 21.5 12 21.5c-4.6 0-9.205-2.583-11.547-4.258-.28-.2-.452-.53-.453-.868v-2.62c0-.345.113-.679.321-.956l.73-.963c.392-.517.974-.654 1.593-.654l.029-.297c.25-2.446.81-4.213 2.082-5.52 2.461-2.54 5.71-2.851 7.146-2.864h.198c1.436.013 4.685.323 7.146 2.864zm-7.244 4.328c-.284 0-.613.016-.962.05-.123.447-.305.85-.57 1.108-1.05 1.023-2.316 1.18-2.994 1.18-.638 0-1.306-.13-1.851-.464-.516.165-1.012.403-1.044.996a65.882 65.882 0 00-.063 2.884l-.002.48c-.002.563-.005 1.126-.013 1.69.002.326.204.63.51.765 2.482 1.102 4.83 1.657 6.99 1.657 2.156 0 4.504-.555 6.985-1.657a.854.854 0 00.51-.766c.03-1.682.006-3.372-.076-5.053-.031-.596-.528-.83-1.046-.996-.546.333-1.212.464-1.85.464-.677 0-1.942-.157-2.993-1.18-.266-.258-.447-.661-.57-1.108-.32-.032-.64-.049-.96-.05zm-2.525 4.013c.539 0 .976.426.976.95v1.753c0 .525-.437.95-.976.95a.964.964 0 01-.976-.95v-1.752c0-.525.437-.951.976-.951zm5 0c.539 0 .976.426.976.95v1.753c0 .525-.437.95-.976.95a.964.964 0 01-.976-.95v-1.752c0-.525.437-.951.976-.951zM7.635 5.087c-1.05.102-1.935.438-2.385.906-.975 1.037-.765 3.668-.21 4.224.405.394 1.17.657 1.995.657h.09c.649-.013 1.785-.176 2.73-1.11.435-.41.705-1.433.675-2.47-.03-.834-.27-1.52-.63-1.813-.39-.336-1.275-.482-2.265-.394zm6.465.394c-.36.292-.6.98-.63 1.813-.03 1.037.24 2.06.675 2.47.968.957 2.136 1.104 2.776 1.11h.044c.825 0 1.59-.263 1.995-.657.555-.556.765-3.187-.21-4.224-.45-.468-1.335-.804-2.385-.906-.99-.088-1.875.058-2.265.394zM12 7.615c-.24 0-.525.015-.84.044.03.16.045.336.06.526l-.001.159a2.94 2.94 0 01-.014.25c.225-.022.425-.027.612-.028h.366c.187 0 .387.006.612.028-.015-.146-.015-.277-.015-.409.015-.19.03-.365.06-.526a9.29 9.29 0 00-.84-.044z", 1),
        ]),
        AgentInfo(id: "cursor", name: "Cursor", layers: [
            ("M22.106 5.68L12.5.135a.998.998 0 00-.998 0L1.893 5.68a.84.84 0 00-.419.726v11.186c0 .3.16.577.42.727l9.607 5.547a.999.999 0 00.998 0l9.608-5.547a.84.84 0 00.42-.727V6.407a.84.84 0 00-.42-.726zm-.603 1.176L12.228 22.92c-.063.108-.228.064-.228-.061V12.34a.59.59 0 00-.295-.51l-9.11-5.26c-.107-.062-.063-.228.062-.228h18.55c.264 0 .428.286.296.514z", 1),
        ]),
        AgentInfo(id: "gemini-cli", name: "Gemini CLI", layers: [
            ("M16.793 10.358v3.867L7.236 18.82v-2.8l7.751-3.728-7.75-3.728V5.763l9.556 4.595z", 1),
            ("M19.608 0A4.392 4.392 0 0124 4.392v15.216A4.392 4.392 0 0119.608 24H4.392A4.392 4.392 0 010 19.608V4.392A4.392 4.392 0 014.392 0h15.216zM4.26 1.444A2.816 2.816 0 001.444 4.26v15.48a2.816 2.816 0 002.816 2.816h15.48a2.816 2.816 0 002.816-2.816V4.26a2.816 2.816 0 00-2.816-2.816H4.26z", 1),
        ]),
        AgentInfo(id: "antigravity", name: "Antigravity", layers: [
            ("M21.751 22.607c1.34 1.005 3.35.335 1.508-1.508C17.73 15.74 18.904 1 12.037 1 5.17 1 6.342 15.74.815 21.1c-2.01 2.009.167 2.511 1.507 1.506 5.192-3.517 4.857-9.714 9.715-9.714 4.857 0 4.522 6.197 9.714 9.715z", 1),
        ]),
        AgentInfo(id: "opencode", name: "OpenCode", layers: [
            ("M16 6H8v12h8V6zm4 16H4V2h16v20z", 1),
        ]),
        AgentInfo(id: "qwen-code", name: "Qwen Code", layers: [
            ("M19.713 2.825h-5.907c0-.251-.066-.503-.196-.728L12.819.728A1.46 1.46 0 0 0 11.559 0h-1.58c-.52 0-1 .275-1.26.728l-2.42 4.19a1.45 1.45 0 0 0 0 1.453l.791 1.37c.26.448.74.727 1.26.727h11.36c.52 0 1-.275 1.26-.728l.79-1.37a1.45 1.45 0 0 0 0-1.451l-.79-1.37a1.46 1.46 0 0 0-1.26-.728zM.195 9.905l2.951 5.115a1.46 1.46 0 0 0-.531.531l-.791 1.37a1.45 1.45 0 0 0 0 1.452l.79 1.37c.26.448.74.727 1.26.727h4.84c.52 0 1-.275 1.26-.728l.79-1.37a1.45 1.45 0 0 0 0-1.451L5.086 7.083a1.46 1.46 0 0 0-1.26-.728h-1.58c-.52 0-1 .276-1.26.728l-.79 1.37a1.45 1.45 0 0 0 0 1.452m15.888 13.367 2.951-5.115c.217.125.469.196.728.196h1.582c.52 0 1-.275 1.26-.728l.79-1.37a1.45 1.45 0 0 0 0-1.451l-2.42-4.191a1.46 1.46 0 0 0-1.259-.728h-1.582c-.52 0-1 .276-1.259.728l-5.678 9.838a1.45 1.45 0 0 0 0 1.452l.79 1.37c.26.448.74.727 1.26.727h1.582c.52 0 1-.275 1.26-.728z", 1),
        ]),
        AgentInfo(id: "kimi-cli", name: "Kimi CLI", layers: [
            ("M21.846 0a1.923 1.923 0 110 3.846H20.15a.226.226 0 01-.227-.226V1.923C19.923.861 20.784 0 21.846 0z", 1),
            ("M11.065 11.199l7.257-7.2c.137-.136.06-.41-.116-.41H14.3a.164.164 0 00-.117.051l-7.82 7.756c-.122.12-.302.013-.302-.179V3.82c0-.127-.083-.23-.185-.23H3.186c-.103 0-.186.103-.186.23V19.77c0 .128.083.23.186.23h2.69c.103 0 .186-.102.186-.23v-3.25c0-.069.025-.135.069-.178l2.424-2.406a.158.158 0 01.205-.023l6.484 4.772a7.677 7.677 0 003.453 1.283c.108.012.2-.095.2-.23v-3.06c0-.117-.07-.212-.164-.227a5.028 5.028 0 01-2.027-.807l-5.613-4.064c-.117-.078-.132-.279-.028-.381z", 1),
        ]),
        AgentInfo(id: "cline", name: "Cline", layers: [
            ("M17.035 3.991c2.75 0 4.98 2.24 4.98 5.003v1.667l1.45 2.896a1.01 1.01 0 01-.002.909l-1.448 2.864v1.668c0 2.762-2.23 5.002-4.98 5.002H7.074c-2.751 0-4.98-2.24-4.98-5.002V17.33l-1.48-2.855a1.01 1.01 0 01-.003-.927l1.482-2.887V8.994c0-2.763 2.23-5.003 4.98-5.003h9.962zM8.265 9.6a2.274 2.274 0 00-2.274 2.274v4.042a2.274 2.274 0 004.547 0v-4.042A2.274 2.274 0 008.265 9.6zm7.326 0a2.274 2.274 0 00-2.274 2.274v4.042a2.274 2.274 0 104.548 0v-4.042A2.274 2.274 0 0015.59 9.6z", 1),
            ("M12.054 5.558a2.779 2.779 0 100-5.558 2.779 2.779 0 000 5.558z", 1),
        ]),
        AgentInfo(id: "roo-code", name: "Roo Code", layers: [
            ("M20.113 5.5l-.442 1.557a.157.157 0 01-.196.106l-7.414-2.157a.16.16 0 00-.143.028l-7.342 5.74a.159.159 0 01-.074.032l-4.37.656a.154.154 0 00-.132.162l.02.245c.005.078.071.14.152.141l5.074.128.058.002 3.75-1.953a.16.16 0 01.164.01l2.657 1.847a.152.152 0 01.066.125l-.023 2.45c0 .032.01.063.028.089l3.737 5.227c.03.04.077.065.129.065h1.182a.153.153 0 00.14-.224l-2.664-4.919a.15.15 0 01.005-.152l1.389-2.169a.156.156 0 01.062-.055l4.965-2.456a.16.16 0 01.158.01l1.418.921a.16.16 0 00.087.026h1.289c.125 0 .2-.136.13-.237l-3.578-5.29c-.074-.109-.246-.082-.282.044z", 1),
        ]),
        AgentInfo(id: "kilo-code", name: "Kilo Code", layers: [
            ("M0 0v24h24V0H0zm22.222 22.222H1.778V1.778h20.444v20.444zm-7.555-4.964h2.222v1.778h-2.794L12.89 17.83v-2.794h1.778v2.222zm4 0h-1.778v-2.222h-2.222v-1.778h2.793l1.207 1.207v2.793zm-7.556-2.591H9.333v-1.778h1.778v1.778zm-5.778-1.778h1.778v4h4v1.778H6.54L5.333 17.46V12.89zm13.334-3.556v1.778h-5.778V9.333h1.987V7.111h-1.987V5.333h2.558l1.206 1.207v2.793h2.014zm-11.556-2h2.222l1.778 1.778v2H9.333v-2H7.111v2H5.333V5.333h1.778v2zm4 0H9.333v-2h1.778v2z", 1),
        ]),
        AgentInfo(id: "kiro", name: "Kiro", layers: [
            ("M4.594 6.677C6.67-2.226 18.746-2.211 21.16 6.632c.353 1.297 1.725 7.582-1.673 13.747-1.545 2.797-5.841 5.49-6.99 1.883C8.6 25.477 3.315 24.1 5.789 18.609l-.318.143c-3.57 1.305-3.863-1.208-3.173-2.513.45-.84.727-1.335.937-1.897.353-.975.458-1.568.593-2.498.27-1.837.277-3.607.765-5.167zm8.37.01a.92.92 0 00-.81.428c-.217.323-.33.825-.33 1.462 0 .705.15 1.89 1.14 1.89h.008c.757 0 1.214-.705 1.214-1.89 0-.622-.127-1.125-.367-1.455a1.014 1.014 0 00-.855-.435zm4.08 0a.92.92 0 00-.81.428c-.217.323-.33.825-.33 1.462 0 .705.15 1.89 1.14 1.89h.008c.757 0 1.215-.705 1.215-1.89 0-.622-.128-1.125-.368-1.455a1.014 1.014 0 00-.855-.435z", 1),
        ]),
        AgentInfo(id: "windsurf", name: "Windsurf", layers: [
            ("M23.78 5.004h-.228a2.187 2.187 0 00-2.18 2.196v4.912c0 .98-.804 1.775-1.76 1.775a1.818 1.818 0 01-1.472-.773L13.168 5.95a2.197 2.197 0 00-1.81-.95c-1.134 0-2.154.972-2.154 2.173v4.94c0 .98-.797 1.775-1.76 1.775-.57 0-1.136-.289-1.472-.773L.408 5.098C.282 4.918 0 5.007 0 5.228v4.284c0 .216.066.426.188.604l5.475 7.889c.324.466.8.812 1.351.938 1.377.316 2.645-.754 2.645-2.117V11.89c0-.98.787-1.775 1.76-1.775h.002c.586 0 1.135.288 1.472.773l4.972 7.163a2.15 2.15 0 001.81.95c1.158 0 2.151-.973 2.151-2.173v-4.939c0-.98.787-1.775 1.76-1.775h.194c.122 0 .22-.1.22-.222V5.225a.221.221 0 00-.22-.222z", 1),
        ]),
        AgentInfo(id: "amp", name: "Amp", layers: [
            ("M15.087 23.18L12.03 24l-2.097-7.823-5.738 5.738-2.251-2.251 5.718-5.719-7.769-2.082.82-3.057 11.294 3.08 3.08 11.295z", 1),
            ("M19.505 18.762l-3.057.82-2.564-9.573-9.572-2.564.819-3.057 11.295 3.079 3.08 11.295z", 1),
            ("M23.893 14.374l-3.057.82-2.565-9.572L8.7 3.057 9.52 0l11.295 3.08 3.079 11.294z", 1),
        ]),
        AgentInfo(id: "goose", name: "Goose", layers: [
            ("M21.595 23.61c1.167-.254 2.405-.944 2.405-.944l-2.167-1.784a12.124 12.124 0 01-2.695-3.131 12.127 12.127 0 00-3.97-4.049l-.794-.462a1.115 1.115 0 01-.488-.815.844.844 0 01.154-.575c.413-.582 2.548-3.115 2.94-3.44.503-.416 1.065-.762 1.586-1.159.074-.056.148-.112.221-.17.003-.002.007-.004.009-.007.167-.131.325-.272.45-.438.453-.524.563-.988.59-1.193-.061-.197-.244-.639-.753-1.148.319.02.705.272 1.056.569.235-.376.481-.773.727-1.171.165-.266-.08-.465-.086-.471h-.001V3.22c-.007-.007-.206-.25-.471-.086-.567.35-1.134.702-1.639 1.021 0 0-.597-.012-1.305.599a2.464 2.464 0 00-.438.45l-.007.009c-.058.072-.114.147-.17.221-.397.521-.743 1.083-1.16 1.587-.323.391-2.857 2.526-3.44 2.94a.842.842 0 01-.574.153 1.115 1.115 0 01-.815-.488l-.462-.794a12.123 12.123 0 00-4.049-3.97 12.133 12.133 0 01-3.13-2.695L1.332 0S.643 1.238.39 2.405c.352.428 1.27 1.49 2.34 2.302C1.58 4.167.73 3.75.06 3.4c-.103.765-.063 1.92.043 2.816.726.317 1.961.806 3.219 1.066-1.006.236-2.11.278-2.961.262.15.554.358 1.119.64 1.688.119.263.25.52.39.77.452.125 2.222.383 3.164.171l-2.51.897a27.776 27.776 0 002.544 2.726c2.031-1.092 2.494-1.241 4.018-2.238-2.467 2.008-3.108 2.828-3.8 3.67l-.483.678c-.25.351-.469.725-.65 1.117-.61 1.31-1.47 4.1-1.47 4.1-.154.486.202.842.674.674 0 0 2.79-.861 4.1-1.47.392-.182.766-.4 1.118-.65l.677-.483c.227-.187.453-.37.701-.586 0 0 1.705 2.02 3.458 3.349l.896-2.511c-.211.942.046 2.712.17 3.163.252.142.509.272.772.392.569.28 1.134.49 1.688.64-.016-.853.026-1.956.261-2.962.26 1.258.75 2.493 1.067 3.219.895.106 2.051.146 2.816.043a73.87 73.87 0 01-1.308-2.67c.811 1.07 1.874 1.988 2.302 2.34h-.001z", 1),
        ]),
        AgentInfo(id: "trae", name: "Trae", layers: [
            ("M24 20.541H3.428v-3.426H0V3.4h24V20.54zM3.428 17.115h17.144V6.827H3.428v10.288zm8.573-5.196l-2.425 2.424-2.424-2.424 2.424-2.424 2.425 2.424zm6.857-.001l-2.424 2.423-2.425-2.423 2.425-2.425 2.424 2.425z", 1),
        ]),
        AgentInfo(id: "qoder", name: "Qoder", layers: [
            ("M23.376 14.458v-4.056c0-2.304-1.003-4.154-2.748-5.075L11.612.574l-.046.086-.045.086c1.68.886 2.644 2.673 2.644 4.902v4.056a7.928 7.928 0 01-.014.454l-.005.061c-.005.081-.01.164-.018.245a4.897 4.897 0 01-.011.1l-.01.076c-.008.068-.015.135-.025.203l-.018.113-.01.058a9.99 9.99 0 01-.098.513l-.007.03a7.209 7.209 0 01-.074.294l-.024.086c-.027.099-.056.197-.087.296l-.027.085a9.592 9.592 0 01-.111.323l-.033.085-.018.046c-.032.082-.064.166-.098.248-.019.048-.04.096-.061.145l-.007.017a6 6 0 01-.084.187c-.024.056-.05.11-.077.165-.03.061-.058.122-.089.182a9.423 9.423 0 01-.176.332c-.03.056-.062.111-.094.167-.031.053-.062.108-.095.16-.033.055-.066.11-.101.164-.033.053-.065.104-.1.155-.034.055-.07.107-.111.169l-.099.144a15.193 15.193 0 01-.34.457c-.04.05-.08.102-.121.151l-.107.128-.007.008a6.987 6.987 0 01-.262.298l-.149.16-.116.12a9.562 9.562 0 01-.204.198l-.03.03-.072.069a9.05 9.05 0 01-.263.235l-.025.022-.029.026-.042.035a11.7 11.7 0 01-.22.18l-.07.055-.018.013a8.904 8.904 0 01-.194.146c-.029.02-.057.042-.086.063a7.7 7.7 0 01-.22.152l-.057.04a8.865 8.865 0 01-.293.185l-.062.037a10.424 10.424 0 01-.307.173l-.037.02-.196.103-.108.052-.012.006a6.196 6.196 0 01-.315.143c-.065.028-.13.054-.196.08l-.035.014-.086.034c-.07.026-.143.05-.215.075l-.039.014-.064.023a8.056 8.056 0 01-.323.097l-.63.173a7.285 7.285 0 01-.33.08l-.07.015c-.053.012-.104.023-.157.032l-.065.011-.085.015a2.332 2.332 0 01-.194.027l-.085.01a4.715 4.715 0 01-.16.018l-.034.003a4.861 4.861 0 01-.246.016h-.033a2.714 2.714 0 01-.155.005h-.106a3.384 3.384 0 01-.225-.007H4.86l-.15-.012-.066-.006a5.586 5.586 0 01-.187-.02l-.04-.005a5.14 5.14 0 01-.219-.035l-.054-.01a6.943 6.943 0 01-.347-.082l-.03-.008-.038-.01a5.034 5.034 0 01-.269-.086l-.063-.023a4.216 4.216 0 01-.188-.073l-.071-.031-.016-.007a4.959 4.959 0 01-.16-.074l-.026-.013a.164.164 0 00-.014-.007l-.671-.351.486.486h.016l8.995 4.742.093.048.03.014.02.01c.056.026.111.052.169.076l.016.008.073.032.195.076.022.008a.718.718 0 01.03.012l.014.004a4.693 4.693 0 00.323.1l.027.007c.073.02.147.038.22.055l.018.004.027.006.066.013.088.016c.075.014.15.026.226.038l.042.004c.064.009.128.016.193.022l.126.012.06.003.05.002.098.005c.046.002.094.002.14.003h.12c.05 0 .1-.002.161-.005h.033l.07-.004a6.17 6.17 0 00.184-.014l.033-.003a.753.753 0 00.058-.005l.108-.012.081-.01.08-.01.129-.021.082-.014.071-.012c.054-.01.107-.021.16-.033l.066-.013.059-.013c.096-.022.192-.046.287-.073l.63-.172a7.354 7.354 0 00.397-.122l.04-.015c.075-.025.149-.051.222-.078.032-.011.062-.024.093-.037l.03-.012c.067-.027.135-.054.2-.082l.128-.056.195-.09.021-.01.102-.05c.068-.034.135-.069.202-.105l.037-.02.073-.038c.08-.044.16-.092.24-.139l.026-.015a8.086 8.086 0 00.322-.2l.065-.045 1.98.902a1.748 1.748 0 002.472-1.59v-7.33l.004.004z", 0.5),
            ("M11.617.576a3.904 3.904 0 00-.093-.047c-.016-.009-.033-.016-.05-.024a5.854 5.854 0 00-.166-.077l-.09-.04a4.094 4.094 0 00-.194-.074c-.017-.006-.035-.015-.053-.02l-.013-.005a5.18 5.18 0 00-.277-.088l-.07-.019a4.034 4.034 0 00-.219-.053c-.015-.003-.03-.008-.044-.012L10.253.1l-.057-.011a5.177 5.177 0 00-.225-.036L9.928.047a5.972 5.972 0 00-.191-.022L9.669.02a1.33 1.33 0 00-.058-.005L9.515.009a4.058 4.058 0 00-.111-.005C9.354 0 9.304 0 9.254 0h-.109c-.052 0-.106.004-.16.004L8.884.01A5.32 5.32 0 008.7.022l-.083.006h-.008c-.05.005-.1.013-.15.019l-.12.014c-.056.008-.112.018-.169.028-.037.006-.074.011-.11.018a7.054 7.054 0 00-.572.133l-.63.172c-.111.031-.22.064-.33.1-.037.011-.072.025-.108.037a12.91 12.91 0 00-.345.126c-.067.027-.133.054-.2.083l-.128.055a11.916 11.916 0 00-.318.15 7.376 7.376 0 00-.311.163c-.082.045-.16.092-.24.14a9.424 9.424 0 00-.35.218l-.016.01-.06.04a9.242 9.242 0 00-.51.37 12.54 12.54 0 00-.315.254l-.043.034-.01.007-.045.041c-.09.078-.18.158-.268.24l-.106.101c-.07.067-.139.135-.207.204l-.056.054-.063.067-.153.164-.12.133-.148.17c-.024.03-.049.057-.073.086l-.043.053a5.96 5.96 0 00-.123.155l-.118.151c-.04.053-.08.106-.118.16l-.075.101-.038.056-.107.155-.11.164a9.91 9.91 0 00-.168.265c-.012.02-.023.043-.037.063a12.43 12.43 0 00-.192.335l-.09.168c-.019.034-.04.07-.057.105-.011.022-.02.043-.032.065l-.092.188-.08.167a19.15 19.15 0 00-.083.192c-.017.038-.035.076-.05.115-.008.016-.014.034-.021.051-.035.083-.067.167-.1.253l-.051.134c-.04.11-.077.22-.113.33l-.02.057c0 .002 0 .005-.002.007l-.008.026c-.032.1-.06.2-.09.301l-.023.089c-.027.1-.052.2-.075.301l-.007.03a7.63 7.63 0 00-.057.267l-.008.048c-.015.074-.026.148-.038.223L.082 8.4c-.011.078-.02.156-.029.234-.006.051-.013.103-.017.154a6.57 6.57 0 00-.02.26c-.003.044-.007.086-.009.13-.004.128-.007.257-.007.386v4.056c0 1.478.42 2.741 1.138 3.692A4.75 4.75 0 002.73 18.67l9.015 4.753c-1.656-.874-2.728-2.685-2.73-5.051v-4.056c0-.13.004-.26.01-.39.002-.043.006-.085.01-.128.005-.088.01-.174.019-.261l.017-.155c.01-.077.018-.155.029-.234l.026-.164c.013-.074.025-.15.039-.223.02-.105.04-.21.064-.313l.008-.031c.023-.1.048-.201.075-.301l.023-.088c.028-.1.058-.202.09-.302l.008-.025.021-.063c.036-.11.073-.22.113-.33l.052-.134c.031-.085.065-.169.1-.253.022-.056.047-.111.07-.166a13.856 13.856 0 01.164-.358c.03-.063.06-.126.092-.188l.088-.172a9.22 9.22 0 01.187-.338l.096-.164c.034-.057.069-.112.104-.168l.1-.159a10.49 10.49 0 01.567-.786l.123-.155.116-.139c.05-.057.098-.115.148-.171a14.092 14.092 0 01.272-.297 9.706 9.706 0 01.432-.425c.088-.083.177-.163.268-.241l.054-.048a10.08 10.08 0 01.553-.435l.092-.068c.075-.053.15-.105.226-.156.019-.013.038-.028.06-.04a9.18 9.18 0 01.362-.227c.08-.047.16-.094.241-.139l.11-.058a7.643 7.643 0 01.521-.256l.126-.056a7.509 7.509 0 01.546-.208l.107-.037c.11-.036.22-.069.33-.1l.63-.172c.095-.026.191-.05.287-.072l.097-.02c.062-.014.125-.029.187-.04l.114-.018c.055-.01.11-.02.166-.028.04-.006.08-.01.12-.014.053-.007.105-.014.157-.019l.083-.006c.061-.005.123-.01.184-.013.034-.003.067-.003.101-.004l.16-.006h.11a3.187 3.187 0 01.261.008l.153.01.067.007c.064.006.128.013.192.022l.043.005a5.232 5.232 0 01.281.047l.141.03c.073.016.146.035.218.053l.07.019c.094.026.187.055.278.087l.067.025a4.326 4.326 0 01.449.19l.143.072L11.617.576z", 1),
        ]),
        AgentInfo(id: "deepseek-harness", name: "DeepSeek Harness", layers: [
            ("M23.748 4.482c-.254-.124-.364.113-.512.234-.051.039-.094.09-.137.136-.372.397-.806.657-1.373.626-.829-.046-1.537.214-2.163.848-.133-.782-.575-1.248-1.247-1.548-.352-.156-.708-.311-.955-.65-.172-.241-.219-.51-.305-.774-.055-.16-.11-.323-.293-.35-.2-.031-.278.136-.356.276-.313.572-.434 1.202-.422 1.84.027 1.436.633 2.58 1.838 3.393.137.093.172.187.129.323-.082.28-.18.552-.266.833-.055.179-.137.217-.329.14a5.526 5.526 0 01-1.736-1.18c-.857-.828-1.631-1.742-2.597-2.458a11.365 11.365 0 00-.689-.471c-.985-.957.13-1.743.388-1.836.27-.098.093-.432-.779-.428-.872.004-1.67.295-2.687.684a3.055 3.055 0 01-.465.137 9.597 9.597 0 00-2.883-.102c-1.885.21-3.39 1.102-4.497 2.623C.082 8.606-.231 10.684.152 12.85c.403 2.284 1.569 4.175 3.36 5.653 1.858 1.533 3.997 2.284 6.438 2.14 1.482-.085 3.133-.284 4.994-1.86.47.234.962.327 1.78.397.63.059 1.236-.03 1.705-.128.735-.156.684-.837.419-.961-2.155-1.004-1.682-.595-2.113-.926 1.096-1.296 2.746-2.642 3.392-7.003.05-.347.007-.565 0-.845-.004-.17.035-.237.23-.256a4.173 4.173 0 001.545-.475c1.396-.763 1.96-2.015 2.093-3.517.02-.23-.004-.467-.247-.588zM11.581 18c-2.089-1.642-3.102-2.183-3.52-2.16-.392.024-.321.471-.235.763.09.288.207.486.371.739.114.167.192.416-.113.603-.673.416-1.842-.14-1.897-.167-1.361-.802-2.5-1.86-3.301-3.307-.774-1.393-1.224-2.887-1.298-4.482-.02-.386.093-.522.477-.592a4.696 4.696 0 011.529-.039c2.132.312 3.946 1.265 5.468 2.774.868.86 1.525 1.887 2.202 2.891.72 1.066 1.494 2.082 2.48 2.914.348.292.625.514.891.677-.802.09-2.14.11-3.054-.614zm1-6.44a.306.306 0 01.415-.287.302.302 0 01.2.288.306.306 0 01-.31.307.303.303 0 01-.304-.308zm3.11 1.596c-.2.081-.399.151-.59.16a1.245 1.245 0 01-.798-.254c-.274-.23-.47-.358-.552-.758a1.73 1.73 0 01.016-.588c.07-.327-.008-.537-.239-.727-.187-.156-.426-.199-.688-.199a.559.559 0 01-.254-.078c-.11-.054-.2-.19-.114-.358.028-.054.16-.186.192-.21.356-.202.767-.136 1.146.016.352.144.618.408 1.001.782.391.451.462.576.685.914.176.265.336.537.445.848.067.195-.019.354-.25.452z", 1),
        ]),
        // Proma 不在 LobeHub Icons 里：取自 Proma 仓库的 resources/proma-logos/icon.svg（六根由近到远的条纹），
        // 32×32 换算到 24×24，透明度照它 1024 图标里由近到远的 1 → 0.25
        AgentInfo(id: "proma", name: "Proma", layers: [
            ("M4.846 7.687L4.846 21.942C4.846 22.112 4.708 22.25 4.539 22.25L1.807 22.25C1.637 22.25 1.5 22.112 1.5 21.942L1.5 7.687C1.5 7.517 1.637 7.38 1.807 7.38L4.539 7.38C4.708 7.38 4.846 7.517 4.846 7.687Z", 1),
            ("M8.597 6.462L9.269 19.294C9.277 19.441 9.164 19.567 9.017 19.574L6.579 19.702C6.432 19.71 6.307 19.597 6.299 19.45L5.627 6.617C5.619 6.47 5.732 6.345 5.879 6.337L8.317 6.21C8.464 6.202 8.589 6.315 8.597 6.462Z", 0.85),
            ("M12.048 5.27L13.244 16.652C13.257 16.777 13.167 16.888 13.043 16.9L10.903 17.126C10.78 17.138 10.669 17.049 10.655 16.924L9.459 5.542C9.446 5.418 9.536 5.307 9.659 5.294L11.8 5.069C11.923 5.056 12.035 5.146 12.048 5.27Z", 0.7),
            ("M15.199 4.106L16.77 14.023C16.786 14.123 16.718 14.218 16.617 14.234L14.778 14.525C14.677 14.54 14.583 14.472 14.567 14.372L12.997 4.455C12.981 4.354 13.049 4.26 13.15 4.244L14.989 3.953C15.089 3.936 15.184 4.005 15.199 4.106Z", 0.55),
            ("M18.055 2.964L19.85 11.41C19.866 11.488 19.817 11.564 19.739 11.58L18.202 11.906C18.125 11.923 18.048 11.874 18.032 11.796L16.237 3.349C16.22 3.272 16.269 3.196 16.347 3.18L17.884 2.852C17.962 2.836 18.038 2.886 18.055 2.964Z", 0.4),
            ("M20.614 1.836L22.485 8.82C22.5 8.875 22.468 8.931 22.413 8.946L21.174 9.278C21.12 9.292 21.063 9.26 21.049 9.205L19.178 2.221C19.163 2.167 19.195 2.111 19.249 2.096L20.489 1.764C20.543 1.75 20.599 1.782 20.614 1.836Z", 0.25),
        ]),
        AgentInfo(id: "codebuddy", name: "CodeBuddy", layers: [
            ("M18.777 1.647c.28-.02.536.114.972.51 1.018.926 2.437 2.828 3.318 4.452l.34.631.482.24.11.06v3.638a5.206 5.206 0 00-5.32-1.23c-.491.166-1.021.471-2.08 1.082l-6.09 3.516c-1.057.61-1.586.916-1.975 1.259a5.208 5.208 0 00-1.493 5.572c.165.49.471 1.02 1.082 2.08l.315.543h-3.26c-.685 0-1.34-.135-1.939-.377-.169-.956-.009-1.789.469-2.335.158-.18.164-.189.13-.493a11.846 11.846 0 01-.057-1.711l.02-.444-.667-1.18C2.1 15.622 1.445 14.078 1.192 12.9c-.133-.647-.125-.934.04-1.146.1-.128.427-.261.822-.334.994-.175 3.162-.017 5.575.41l.25.043.551-.487c.915-.81 1.522-1.264 2.641-1.962 1.167-.73 2.484-1.331 3.967-1.807l.476-.152.261-.688c.937-2.471 1.896-4.293 2.58-4.9.235-.21.25-.22.422-.23z", 1),
            ("M12.139 18.2a1.203 1.203 0 011.642.44l1.296 2.243a1.204 1.204 0 01-2.083 1.203l-1.296-2.243a1.203 1.203 0 01.44-1.644zM18.629 14.452a1.203 1.203 0 011.642.44l1.295 2.244a1.203 1.203 0 11-2.083 1.203l-1.295-2.243a1.203 1.203 0 01.44-1.644z", 1),
        ]),
    ]
}

/// agent 的小标志：单色，跟着 foregroundStyle 走；读屏读 agent 名字
public struct AgentGlyph: View {
    let info: AgentInfo
    let size: CGFloat

    public init(_ agent: String?, size: CGFloat = 14) {
        info = Agents.info(agent)
        self.size = size
    }

    public var body: some View {
        Group {
            if info.layers.isEmpty {
                Text(info.name.prefix(1).uppercased())
                    .font(.system(size: size * 0.6, weight: .bold, design: .rounded))
                    .frame(width: size, height: size)
                    .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).stroke(lineWidth: max(1, size / 14)))
            } else {
                ZStack {
                    ForEach(info.layers.indices, id: \.self) { index in
                        AgentShape(d: info.layers[index].d)
                            .fill(style: FillStyle(eoFill: true))
                            .opacity(info.layers[index].opacity)
                    }
                }
                .frame(width: size, height: size)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(info.name)
    }
}

/// 一层标志：24×24 的路径等比缩放到给的框里、居中
struct AgentShape: Shape {
    let d: String

    func path(in rect: CGRect) -> Path {
        guard let base = Agents.paths[d] ?? Agents.extra.path(d) else { return Path() }
        let unit = min(rect.width, rect.height) / 24
        var transform = CGAffineTransform(translationX: rect.midX - 12 * unit, y: rect.midY - 12 * unit).scaledBy(x: unit, y: unit)
        return base.copy(using: &transform).map(Path.init) ?? Path()
    }
}

/// 电脑端插件给的一个 agent：{id, name, speaker?, mark?}。mark 是 24×24 画布的单色 SVG 路径，
/// 可以是一条路径字符串、[{d, opacity}]，或 {"svg": 路径}。怎么写都不让整份数据解析失败
public struct AgentProfile: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let speaker: String?
    let layers: [(d: String, opacity: Double)]
    /// 插件要求的最低 iPhone 版本（minApp.ios）
    public let minIOS: String?
    public var hasMark: Bool { !layers.isEmpty }

    private struct Layer: Codable { var d: String?; var opacity: Double? }
    private struct Wrapped: Decodable { var svg: String?; var d: String? }
    private struct Minimum: Codable { var ios: String? }
    private enum CodingKeys: String, CodingKey { case id, name, speaker, mark, minApp }

    public init(from decoder: Decoder) {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        id = (try? c?.decodeIfPresent(String.self, forKey: .id)) ?? nil ?? ""
        name = (try? c?.decodeIfPresent(String.self, forKey: .name)) ?? nil ?? ""
        speaker = ((try? c?.decodeIfPresent(String.self, forKey: .speaker)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        minIOS = ((try? c?.decodeIfPresent(Minimum.self, forKey: .minApp)) ?? nil)?.ios.flatMap { $0.isEmpty ? nil : $0 }
        if let path = (try? c?.decodeIfPresent(String.self, forKey: .mark)) ?? nil {
            layers = [(path, 1)]
        } else if let list = (try? c?.decodeIfPresent([Layer].self, forKey: .mark)) ?? nil {
            layers = list.compactMap { layer in layer.d.map { ($0, layer.opacity ?? 1) } }
        } else if let one = (try? c?.decodeIfPresent(Wrapped.self, forKey: .mark)) ?? nil, let path = one.svg ?? one.d {
            layers = [(path, 1)]
        } else {
            layers = []
        }
    }

    /// 转给手表时用：标志统一写成 [{d, opacity}]
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(speaker, forKey: .speaker)
        try c.encode(layers.map { Layer(d: $0.d, opacity: $0.opacity) }, forKey: .mark)
        if let minIOS { try c.encode(Minimum(ios: minIOS), forKey: .minApp) }
    }

    public static func == (a: AgentProfile, b: AgentProfile) -> Bool {
        a.id == b.id && a.name == b.name && a.speaker == b.speaker && a.minIOS == b.minIOS
            && a.layers.map(\.d) == b.layers.map(\.d) && a.layers.map(\.opacity) == b.layers.map(\.opacity)
    }
}

/// 插件给的 agent 和解析好的路径；界面线程更新、画标志时读，加锁
private final class Registered: @unchecked Sendable {
    private let lock = NSLock()
    private var infos: [String: AgentInfo] = [:]
    private var paths: [String: CGPath] = [:]
    private var minimums: [String: String] = [:]

    func minimum(_ id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return minimums[id]
    }

    func set(_ cards: [AgentProfile], minimums: [String: String]) {
        var infos: [String: AgentInfo] = [:]
        var paths: [String: CGPath] = [:]
        for card in cards {
            let layers = card.layers.filter { !$0.d.isEmpty && $0.d.utf8.count < 20_000 }.prefix(8)
            infos[card.id] = AgentInfo(id: card.id, name: card.name, layers: Array(layers), spoken: card.speaker)
            for layer in layers where paths[layer.d] == nil { paths[layer.d] = self.path(layer.d) ?? SVGPath.parse(layer.d) }
        }
        lock.lock(); self.infos = infos; self.paths = paths; self.minimums = minimums; lock.unlock()
    }

    func info(_ id: String) -> AgentInfo? {
        lock.lock(); defer { lock.unlock() }
        return infos[id]
    }

    func path(_ d: String) -> CGPath? {
        lock.lock(); defer { lock.unlock() }
        return paths[d]
    }
}

/// SVG 路径（d 属性）→ CGPath：M L H V C S Q T A Z（大小写都认），圆弧换成三次贝塞尔。
/// 只用来画上面收录的标志，写坏的路径画到哪算哪，不会卡住
enum SVGPath {
    static func parse(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var reader = Reader(Array(d.utf8))
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?      // 上一段三次曲线的第二控制点（S 用）
        var lastQuad: CGPoint?         // 上一段二次曲线的控制点（T 用）
        var command: UInt8 = 0

        while reader.skipSeparators() {
            if let letter = reader.command() {
                command = letter
            } else if command == 0 {
                break
            }
            let relative = command >= 97   // 小写 = 相对坐标
            let origin = relative ? current : .zero
            func point() -> CGPoint? {
                guard let x = reader.number(), let y = reader.number() else { return nil }
                return CGPoint(x: origin.x + x, y: origin.y + y)
            }
            var cubic: CGPoint?
            var quad: CGPoint?

            switch command | 0x20 {        // 统一成小写判断
            case UInt8(ascii: "m"):
                guard let p = point() else { return path }
                path.move(to: p)
                current = p
                start = p
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")   // 后面接着的坐标对按直线画
            case UInt8(ascii: "l"):
                guard let p = point() else { return path }
                path.addLine(to: p)
                current = p
            case UInt8(ascii: "h"):
                guard let x = reader.number() else { return path }
                current.x = relative ? current.x + x : x
                path.addLine(to: current)
            case UInt8(ascii: "v"):
                guard let y = reader.number() else { return path }
                current.y = relative ? current.y + y : y
                path.addLine(to: current)
            case UInt8(ascii: "c"):
                guard let c1 = point(), let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                cubic = c2
                current = p
            case UInt8(ascii: "s"):
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                guard let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                cubic = c2
                current = p
            case UInt8(ascii: "q"):
                guard let c = point(), let p = point() else { return path }
                path.addQuadCurve(to: p, control: c)
                quad = c
                current = p
            case UInt8(ascii: "t"):
                let c = lastQuad.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                guard let p = point() else { return path }
                path.addQuadCurve(to: p, control: c)
                quad = c
                current = p
            case UInt8(ascii: "a"):
                guard let rx = reader.number(), let ry = reader.number(), let angle = reader.number(),
                      let large = reader.flag(), let sweep = reader.flag(), let p = point() else { return path }
                addArc(path, from: current, to: p, rx: rx, ry: ry, angle: angle, large: large, sweep: sweep)
                current = p
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = start
                command = 0                 // z 后面必须跟新的指令
            default:
                return path
            }
            lastControl = cubic
            lastQuad = quad
        }
        return path
    }

    /// SVG 规范附录 F.6 的端点式圆弧 → 中心式 → 每段不超过 90° 的三次贝塞尔
    private static func addArc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat,
                               angle: CGFloat, large: Bool, sweep: Bool) {
        guard p0 != p1 else { return }
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0 else { path.addLine(to: p1); return }
        let phi = angle * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coefficient = denominator == 0 ? 0 : sqrt(max(0, numerator / denominator))
        if large == sweep { coefficient = -coefficient }
        let cxp = coefficient * rx * y1 / ry
        let cyp = -coefficient * ry * x1 / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2
        let ux = (x1 - cxp) / rx, uy = (y1 - cyp) / ry
        let vx = (-x1 - cxp) / rx, vy = (-y1 - cyp) / ry
        let theta = atan2(uy, ux)
        var delta = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2) - 0.001)))
        let step = delta / CGFloat(segments)
        let k = 4 / 3 * tan(step / 4)
        func onEllipse(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: cx + cosPhi * x - sinPhi * y, y: cy + sinPhi * x + cosPhi * y)
        }
        for index in 0..<segments {
            let a1 = theta + CGFloat(index) * step, a2 = a1 + step
            let cos1 = cos(a1), sin1 = sin(a1), cos2 = cos(a2), sin2 = sin(a2)
            let c1 = onEllipse(rx * (cos1 - k * sin1), ry * (sin1 + k * cos1))
            let c2 = onEllipse(rx * (cos2 + k * sin2), ry * (sin2 - k * cos2))
            let end = index == segments - 1 ? p1 : onEllipse(rx * cos2, ry * sin2)
            path.addCurve(to: end, control1: c1, control2: c2)
        }
    }

    /// 逐个读指令字母、数字；圆弧的两个标志位可以挤在一起写（「01」= 0 和 1），单独读
    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        /// 跳过空白和逗号；读完了返回 false
        mutating func skipSeparators() -> Bool {
            while index < bytes.count, bytes[index] == 32 || bytes[index] == 44 || (9...13).contains(bytes[index]) { index += 1 }
            return index < bytes.count
        }

        mutating func command() -> UInt8? {
            let byte = bytes[index]
            guard (65...90).contains(byte) || (97...122).contains(byte), byte != UInt8(ascii: "e"), byte != UInt8(ascii: "E") else { return nil }
            index += 1
            return byte
        }

        mutating func flag() -> Bool? {
            guard skipSeparators(), bytes[index] == UInt8(ascii: "0") || bytes[index] == UInt8(ascii: "1") else { return nil }
            defer { index += 1 }
            return bytes[index] == UInt8(ascii: "1")
        }

        mutating func number() -> CGFloat? {
            guard skipSeparators() else { return nil }
            let begin = index
            if bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
            var digits = false, dot = false
            while index < bytes.count {
                let byte = bytes[index]
                if (48...57).contains(byte) {
                    digits = true
                } else if byte == UInt8(ascii: "."), !dot {
                    dot = true
                } else {
                    break
                }
                index += 1
            }
            if digits, index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                var look = index + 1
                if look < bytes.count, bytes[look] == UInt8(ascii: "-") || bytes[look] == UInt8(ascii: "+") { look += 1 }
                if look < bytes.count, (48...57).contains(bytes[look]) {
                    index = look
                    while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
                }
            }
            guard digits, let value = Double(String(decoding: bytes[begin..<index], as: UTF8.self)) else {
                index = begin
                return nil
            }
            return CGFloat(value)
        }
    }
}
