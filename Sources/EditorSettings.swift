import Foundation
import SQLite3

/// VS Code（及 Insiders、VSCodium、Cursor）的用户设置：替用户免掉 Kiteline 自己会撞上的确认框。
///
/// Kiteline 用扩展链接 vscode://anthropic.claude-code/open 切会话、开新任务，新装的 VS Code 每次都先弹
/// 「是否允许“Claude Code”扩展打开此 URI?」：用户在手机上用、人不在电脑前时没人点，消息就卡住；
/// 投完 Kiteline 还会把前台还回去，框被压到后面，在电脑前看也像是自己消失了。
/// VS Code 有现成的设置 extensions.confirmedUriHandlerExtensionIds（列出的扩展打开链接不再确认，等同在框里勾「不再询问」），
/// 这里只往用户设置里加这一项，别的设置、注释、格式原样不动；设置文件看不懂就不碰，照旧弹框（投递时提示用户去电脑上点）。
///
/// 打开项目窗口的确认框（security.promptFor…FileProtocolHandling）不替用户关：它防的是网页随便让 VS Code 开文件夹，
/// Kiteline 改用启动参数开窗口绕开它（见 WindowLocator.open），这里只读它判断要不要绕。
enum EditorSettings {
    static let claudeExtension = "anthropic.claude-code"
    static let trustKey = "extensions.confirmedUriHandlerExtensionIds"
    private static let lock = NSLock()

    /// 编辑器的用户目录 ~/Library/Application Support/<Code…>/User
    static func userDirectory(scheme: String) -> URL {
        let folder: String
        switch scheme {
        case "vscode-insiders": folder = "Code - Insiders"
        case "vscodium": folder = "VSCodium"
        case "cursor": folder = "Cursor"
        default: folder = "Code"
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/\(folder)/User")
    }

    /// 启动时把装过的编辑器都设好（第一次切会话就不用等 VS Code 读新设置）
    static func trustInstalledEditors() {
        DispatchQueue.global(qos: .utility).async {
            for editor in Delivery.Editor.known { trustClaudeLinks(scheme: editor.scheme) }
        }
    }

    /// 让 Claude Code 扩展的链接不再弹确认框。trusted = 之后不会弹；wrote = 这次刚写进设置（VS Code 要一会儿才读到）
    @discardableResult
    static func trustClaudeLinks(scheme: String) -> (trusted: Bool, wrote: Bool) {
        trustClaudeLinks(in: userDirectory(scheme: scheme))
    }

    static func trustClaudeLinks(in user: URL) -> (trusted: Bool, wrote: Bool) {
        // 启动时在后台设、投递时在主线程查：同时进来会各插一遍
        lock.lock()
        defer { lock.unlock() }
        // 设置文件可能是链到 dotfiles 仓库的符号链接：写到它指向的文件，链接本身留着
        let file = user.appendingPathComponent("settings.json").resolvingSymlinksInPath()
        var text = ""
        if let data = FileManager.default.contents(atPath: file.path) {
            guard let decoded = String(data: data, encoding: .utf8) else { return (false, false) }
            text = decoded
        } else if !FileManager.default.fileExists(atPath: user.path) {
            return (false, false)   // 没装或没打开过这个编辑器
        }
        if let settings = parse(text), lists(settings) { return (true, false) }
        if confirmedInStorage(user) { return (true, false) }
        guard let updated = addingClaudeTrust(to: text) else {
            Log.write("VS Code 设置文件无法解析，未能预先信任 Claude Code 扩展的链接（\(file.path)）：切换会话时 VS Code 会弹确认框")
            return (false, false)
        }
        do {
            try Data(updated.utf8).write(to: file, options: .atomic)
        } catch {
            Log.write("写 VS Code 设置失败（\(file.path)）：\(error.localizedDescription)")
            return (false, false)
        }
        Log.write("已在 VS Code 设置中信任 Claude Code 扩展的链接（\(trustKey)），切换会话、新任务不再弹确认框")
        return (true, true)
    }

    /// 只查不写：Claude Code 扩展的链接会不会弹确认框（就绪检查在测试实例里用，不碰用户的 VS Code 设置）
    static func claudeLinksTrusted(scheme: String) -> Bool {
        let user = userDirectory(scheme: scheme)
        if let settings = settings(scheme: scheme), lists(settings) { return true }
        return confirmedInStorage(user)
    }

    /// 装过（打开过）这个编辑器：用户目录在
    static func installed(scheme: String) -> Bool {
        FileManager.default.fileExists(atPath: userDirectory(scheme: scheme).path)
    }

    /// VS Code 开着工作区信任（默认开）：没信任过的文件夹以受限模式打开（顶上挂横幅，不弹框），
    /// 信任之前 Claude Code 扩展不运行（它声明了不支持未受信任的工作区）
    static func workspaceTrustEnabled(scheme: String) -> Bool {
        settings(scheme: scheme)?["security.workspace.trust.enabled"] as? Bool != false
    }

    /// VS Code 设置里给 Claude Code 配的环境变量（claudeCode.environmentVariables，[{name, value}]）。
    /// Remote-SSH 时扩展在远端运行，用的仍是本地的这项设置；后台运行 Claude Code 时只取其中网络相关的（watcher 再筛一遍）
    static func claudeEnvironment(scheme: String) -> [String: String] {
        guard let settings = settings(scheme: scheme) else { return [:] }
        let list = settings["claudeCode.environmentVariables"] ?? settings["claude-code.environmentVariables"]
        var out: [String: String] = [:]
        for item in list as? [[String: Any]] ?? [] {
            if let name = item["name"] as? String, let value = item["value"] as? String { out[name] = value }
        }
        return out
    }

    private static func settings(scheme: String) -> [String: Any]? {
        let file = userDirectory(scheme: scheme).appendingPathComponent("settings.json")
        guard let data = FileManager.default.contents(atPath: file.path), let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(text)
    }

    /// 打开项目窗口的 vscode://file、vscode-remote 链接会不会先弹「外部应用程序想要打开…」
    /// （默认会；用户在框里勾了「不再询问」，VS Code 把对应的设置写成 false）
    static func promptsForFolderLinks(remote: Bool, scheme: String) -> Bool {
        let key = remote ? "security.promptForRemoteFileProtocolHandling" : "security.promptForLocalFileProtocolHandling"
        return settings(scheme: scheme)?[key] as? Bool != false
    }

    private static func lists(_ settings: [String: Any]) -> Bool {
        (settings[trustKey] as? [Any])?.contains { ($0 as? String)?.lowercased() == claudeExtension } ?? false
    }

    /// 用户在确认框里勾过「不再询问」：VS Code 记在 globalStorage/state.vscdb 的 extensionUrlHandler.confirmedExtensions
    private static func confirmedInStorage(_ user: URL) -> Bool {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(user.appendingPathComponent("globalStorage/state.vscdb").path, &db,
                              SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
        sqlite3_busy_timeout(db, 500)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = 'extensionUrlHandler.confirmedExtensions'",
                                 -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return false }
        let ids = (try? JSONSerialization.jsonObject(with: Data(String(cString: value).utf8))) as? [String] ?? []
        return ids.contains { $0.lowercased() == claudeExtension }
    }

    // MARK: - JSONC（VS Code 的设置文件允许注释和结尾多余的逗号）

    /// 往设置里加上信任 Claude Code 扩展链接的那一项，别的原样不动；已经有了返回原文，看不懂（或这项不是数组）返回 nil
    static func addingClaudeTrust(to text: String) -> String? {
        let item = "\"\(claudeExtension)\""
        if text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))).isEmpty {
            return "{\n    \"\(trustKey)\": [\(item)]\n}\n"
        }
        guard let settings = parse(text) else { return nil }
        if lists(settings) { return text }
        if settings[trustKey] != nil, !(settings[trustKey] is [Any]) { return nil }
        let chars = Array(text)
        let list = tokens(chars)
        var depth = 0
        var key: String?, pending: String?
        var root: Int?, array: Int?
        for (index, token) in list.enumerated() {
            guard let symbol = token.symbol else {
                if depth == 1 { pending = token.string }
                continue
            }
            switch symbol {
            case "{", "[":
                if depth == 0, symbol == "{", root == nil { root = index }
                if depth == 1, symbol == "[", key == trustKey { array = index }
                depth += 1
                key = nil
            case "}", "]":
                depth -= 1
            case ":":
                key = depth == 1 ? pending : nil
            default:   // ,
                key = nil
                pending = nil
            }
        }
        guard let open = array ?? root else { return nil }
        let empty = open + 1 < list.count && list[open + 1].symbol == (array != nil ? "]" : "}")
        let insert = array != nil
            ? (empty ? item : item + ", ")
            : "\n    \"\(trustKey)\": [\(item)]" + (empty ? "\n" : ",")
        let at = list[open].at + 1
        return String(chars[..<at]) + insert + String(chars[at...])
    }

    /// 去掉注释和结尾多余的逗号再解析；空文件当 {}，看不懂返回 nil
    static func parse(_ text: String) -> [String: Any]? {
        let chars = Array(text)
        var out: [Character] = []
        var lastSignificant: Int?   // out 里上一个不是空白的位置（去结尾逗号用）
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\"" {
                let end = stringEnd(chars, from: index)
                out.append(contentsOf: chars[index..<min(end + 1, chars.count)])
                lastSignificant = out.count - 1
                index = end + 1
            } else if let skip = commentEnd(chars, at: index) {
                index = skip
            } else {
                if (char == "}" || char == "]"), let last = lastSignificant, out[last] == "," { out.remove(at: last) }
                if char != "\u{FEFF}" { out.append(char) }
                if !char.isWhitespace && char != "\u{FEFF}" { lastSignificant = out.count - 1 }
                index += 1
            }
        }
        let cleaned = String(out)
        if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: Data(cleaned.utf8))) as? [String: Any]
    }

    private struct Token {
        var symbol: Character?   // { } [ ] : ,
        var string: String?      // 字符串内容（没解转义，比键名够用）
        var at: Int              // 在 Character 数组里的位置
    }

    /// 注释以外的符号和字符串
    private static func tokens(_ chars: [Character]) -> [Token] {
        var result: [Token] = []
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\"" {
                let end = stringEnd(chars, from: index)
                result.append(Token(symbol: nil, string: String(chars[(index + 1)..<min(end, chars.count)]), at: index))
                index = end + 1
            } else if let skip = commentEnd(chars, at: index) {
                index = skip
            } else {
                if "{}[]:,".contains(char) { result.append(Token(symbol: char, string: nil, at: index)) }
                index += 1
            }
        }
        return result
    }

    /// 从开头的引号起，找到收尾引号的位置（跳过 \" 这类转义）
    private static func stringEnd(_ chars: [Character], from start: Int) -> Int {
        var end = start + 1
        while end < chars.count, chars[end] != "\"" { end += chars[end] == "\\" ? 2 : 1 }
        return end
    }

    /// index 处是注释的话返回注释后面的位置
    private static func commentEnd(_ chars: [Character], at index: Int) -> Int? {
        guard chars[index] == "/", index + 1 < chars.count else { return nil }
        if chars[index + 1] == "/" {
            var end = index
            while end < chars.count, !chars[end].isNewline { end += 1 }
            return end
        }
        if chars[index + 1] == "*" {
            var end = index + 2
            while end + 1 < chars.count, !(chars[end] == "*" && chars[end + 1] == "/") { end += 1 }
            return min(end + 2, chars.count)
        }
        return nil
    }
}
