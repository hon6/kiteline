import Foundation
import Observation
import SwiftUI

/// 提示词链接（借鉴 T3 Code）：https://tars.betac.cn/new#p=<提示词>&project=<项目名或路径>，或 kiteline://new#…（官网 /new 页上的按钮、
/// Mac / Windows / Linux 注册的网址协议）。打开后弹「新任务」：提示词填好、能认出项目就选中，用户看过、改好再开始，不会自己执行。
/// 提示词放在 # 后面：浏览器不会把它发到服务器。iPhone 上装了 App 时，系统按通用链接直接打开 App（官网 /.well-known/apple-app-site-association）
public struct PromptLink: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let prompt: String
    /// 项目：目录名（shop-app）、完整路径或 owner/repo，按目录名对电脑上的项目
    public let project: String?

    public static let site = "tars.betac.cn"

    public init(prompt: String, project: String?) {
        self.prompt = prompt
        self.project = project
    }

    public static func parse(_ url: URL) -> PromptLink? {
        switch url.scheme?.lowercased() {
        case "kiteline": guard url.host?.lowercased() == "new" else { return nil }
        case "https": guard url.host?.lowercased() == site, url.path == "/new" || url.path == "/new/" else { return nil }
        default: return nil
        }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var fields: [String: String] = [:]
        for raw in [parts?.percentEncodedQuery, parts?.percentEncodedFragment].compactMap({ $0 }) {
            for pair in raw.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                // 别的工具生成的链接可能把空格写成 +；我们自己生成的会把 + 编成 %2B
                let decode = { (s: String) in s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s }
                fields[decode(kv[0])] = kv.count > 1 ? decode(kv[1]) : ""
            }
        }
        let prompt = (fields["p"] ?? fields["prompt"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }
        let project = (fields["project"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return PromptLink(prompt: String(prompt.prefix(20000)), project: project.isEmpty ? nil : project)
    }

    /// 做一条链接（复制给别人、放进 PR 评论）
    public static func make(prompt: String, project: String?) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        var link = "https://\(site)/new#p=" + enc(prompt)
        if let project, !project.isEmpty { link += "&project=" + enc(project) }
        return link
    }

    /// 链接里的项目对得上哪些项目（目录名、整条路径、owner/repo 的最后一级，不分大小写）
    public static func matches(_ hint: String, cwd: String, name: String) -> Bool {
        let trimmed = hint.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        let last = trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? trimmed
        let dir = cwd.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return dir.caseInsensitiveCompare(trimmed.replacingOccurrences(of: "\\", with: "/")) == .orderedSame
            || name.caseInsensitiveCompare(last) == .orderedSame
    }
}

/// 收到、还没弹出来的提示词链接（App 收到链接时界面可能还没搭好：主界面出来再弹）
@MainActor @Observable
public final class PromptLinks {
    public static let shared = PromptLinks()
    public var pending: PromptLink?

    /// 是提示词链接就收下，返回 true
    @discardableResult
    public func receive(_ url: URL) -> Bool {
        guard let link = PromptLink.parse(url) else { return false }
        pending = link
        return true
    }
}

#if os(iOS)
/// 主界面上挂着：收到提示词链接就弹「新任务」（提示词填好，链接里的项目对得上就选中）
struct PromptLinkHost: ViewModifier {
    /// 挂在主界面 .environment(model) 外面：面板里要自己带上
    let model: AppModel
    @State private var links = PromptLinks.shared

    func body(content: Content) -> some View {
        content.sheet(item: $links.pending) { link in
            NewTaskView(initialText: link.prompt, hint: link.project).environment(model)
        }
    }
}
#endif
