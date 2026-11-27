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

    /// 步骤那一行开头的动作名（读取、编辑、运行命令……），不认识的工具照原名
    static func verb(_ item: ChatItem) -> String {
        switch item.name ?? "" {
        case "Bash": return isTest(item.input?["command"]?.string ?? "") ? L("运行测试") : L("运行命令")
        case "Read": return L("读取")
        case "Edit", "MultiEdit": return L("编辑")
        case "Write": return L("写入")
        case "NotebookEdit": return L("编辑笔记本")
        case "Grep": return L("搜索")
        case "Glob": return L("查找文件")
        case "WebFetch": return L("打开网页")
        case "WebSearch": return L("网上搜索")
        case "Skill": return L("技能")
        case "SendMessage": return L("发送消息")
        case "ToolSearch": return L("加载工具")
        default: return displayName(item.name)
        }
    }

    /// 命令是不是在跑测试（swift test、pytest、npm test……）
    static func isTest(_ command: String) -> Bool {
        command.range(of: testPattern, options: .regularExpression) != nil
    }

    static let testPattern = #"(^|[\s;&|(])(pytest|jest|vitest|rspec|phpunit|ctest|(swift|go|cargo|dotnet|mvn|deno|bun|make|flutter|mix) test|(npm|pnpm|yarn)( run)? test|python3? -m (pytest|unittest)|xcodebuild\b.*\btest|\S*gradlew? \S*test)\b"#

    /// SF Symbols 图标
    static func symbol(_ name: String?) -> String {
        switch name ?? "" {
        case "SendMessage": return "paperplane"
        case "TodoWrite": return "checklist"
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Edit", "MultiEdit", "NotebookEdit": return "square.and.pencil"
        case "Write": return "doc.badge.plus"
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
