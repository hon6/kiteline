import Foundation

/// 工具在对话里怎么显示：和 VS Code 里的 Claude Code 一致，常用工具保留英文名，交互类的译成中文
enum Tools {
    static func displayName(_ name: String?) -> String {
        switch name ?? "" {
        case "AskUserQuestion": return L("提问")
        case "ExitPlanMode": return L("计划")
        case "TodoWrite": return L("任务清单")
        case "Task", "Agent": return L("子任务")
        default: return name ?? L("工具")
        }
    }

    /// SF Symbols 图标
    static func symbol(_ name: String?) -> String {
        switch name ?? "" {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Edit", "MultiEdit": return "pencil"
        case "Write": return "doc.badge.plus"
        case "NotebookEdit": return "book.closed"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Task", "Agent": return "person.2"
        case "AskUserQuestion": return "questionmark.bubble"
        case "ExitPlanMode": return "map"
        case "Skill": return "puzzlepiece.extension"
        default: return "wrench.and.screwdriver"
        }
    }

    /// 步骤那一行右边的简述（命令、文件名、搜索词……）
    static func brief(_ item: ChatItem) -> String {
        let input = item.input
        func field(_ key: String) -> String { input?[key]?.string ?? "" }
        switch item.name ?? "" {
        case "Bash":
            let command = field("command")
            return command.isEmpty ? field("description") : String(command.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
        case "Read":
            let offset = field("offset")
            return basename(field("file_path")) + (offset.isEmpty ? "" : ":\(offset)")
        case "Edit", "MultiEdit", "Write":
            return basename(field("file_path"))
        case "NotebookEdit":
            return basename(field("notebook_path"))
        case "Grep":
            let path = field("path")
            return field("pattern") + (path.isEmpty ? "" : "  " + basename(path))
        case "Glob":
            return field("pattern")
        case "WebFetch":
            return field("url").replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
        case "WebSearch":
            return field("query")
        case "Task", "Agent":
            return field("description")
        case "AskUserQuestion":
            return input?["questions"]?.array.first?["question"]?.string ?? ""
        case "ExitPlanMode":
            return L("等待批准")
        case "Skill":
            let skill = field("skill")
            return skill.isEmpty ? field("name") : skill
        default:
            let brief = item.brief ?? ""
            if let name = item.name, brief.hasPrefix(name) {
                return String(brief.dropFirst(name.count)).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            }
            return brief
        }
    }

    /// 改了多少行：(+新增, −删除)，不是改文件的工具为空
    static func diffStat(_ item: ChatItem) -> (added: Int, removed: Int)? {
        let input = item.input
        func lines(_ value: JSONValue?) -> Int {
            guard let text = value?.string, !text.isEmpty else { return 0 }
            return text.split(separator: "\n", omittingEmptySubsequences: false).count
        }
        switch item.name ?? "" {
        case "Edit":
            return (lines(input?["new_string"]), lines(input?["old_string"]))
        case "MultiEdit":
            return (input?["edits"]?.array ?? []).reduce((0, 0)) { ($0.0 + lines($1["new_string"]), $0.1 + lines($1["old_string"])) }
        case "Write":
            return (lines(input?["content"]), 0)
        default:
            return nil
        }
    }

    static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

/// 模型 id → 人话（claude-opus-5-5 → Opus 5.5）
func modelName(_ id: String?) -> String {
    guard let id, !id.isEmpty else { return "" }
    let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
    guard let family = parts.first else { return id }
    let version = parts.dropFirst().prefix { $0.allSatisfy(\.isNumber) && $0.count <= 2 }.joined(separator: ".")
    return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
}
