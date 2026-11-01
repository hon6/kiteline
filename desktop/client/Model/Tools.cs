using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using static Kiteline.Lang;

namespace Kiteline.Model;

/// 工具在对话里怎么显示（同 iOS 版 Model/Tools.swift）：常用工具保留英文名，交互类的译成中文
public static class Tools
{
    public static string DisplayName(string? name) => name switch
    {
        "AskUserQuestion" => L("提问"),
        "ExitPlanMode" => L("计划"),
        "TodoWrite" => L("任务清单"),
        "Task" or "Agent" => L("子任务"),
        null or "" => L("工具"),
        _ => name,
    };

    /// 图标（SF Symbols 的名字，Icons 里换成对应的 Fluent 图标）
    public static string Symbol(string? name) => name switch
    {
        "Bash" => "terminal",
        "Read" => "doc.text",
        "Edit" or "MultiEdit" => "pencil",
        "Write" => "doc.badge.plus",
        "NotebookEdit" => "book.closed",
        "Grep" or "Glob" => "magnifyingglass",
        "WebFetch" or "WebSearch" => "globe",
        "Task" or "Agent" => "person.2",
        "AskUserQuestion" => "questionmark.bubble",
        "ExitPlanMode" => "map",
        "Skill" => "puzzlepiece.extension",
        _ => "wrench.and.screwdriver",
    };

    /// 步骤那一行右边的简述（命令、文件名、搜索词……）
    public static string Brief(ChatItem item)
    {
        var input = item.Input;
        string Field(string key) => input.Str(key) ?? "";
        switch (item.Name ?? "")
        {
            case "Bash":
                var command = Field("command");
                return command.Length == 0 ? Field("description") : command.Split('\n')[0];
            case "Read":
                var offset = Field("offset");
                return Basename(Field("file_path")) + (offset.Length == 0 ? "" : ":" + offset);
            case "Edit" or "MultiEdit" or "Write":
                return Basename(Field("file_path"));
            case "NotebookEdit":
                return Basename(Field("notebook_path"));
            case "Grep":
                var path = Field("path");
                return Field("pattern") + (path.Length == 0 ? "" : "  " + Basename(path));
            case "Glob":
                return Field("pattern");
            case "WebFetch":
                return Regex.Replace(Field("url"), "^https?://", "");
            case "WebSearch":
                return Field("query");
            case "Task" or "Agent":
                return Field("description");
            case "AskUserQuestion":
                return input.Arr("questions")?.Items().FirstOrDefault().Str("question") ?? "";
            case "ExitPlanMode":
                return L("等待批准");
            case "Skill":
                var skill = Field("skill");
                return skill.Length == 0 ? Field("name") : skill;
            default:
                var brief = item.Brief ?? "";
                if (item.Name is string n && brief.StartsWith(n)) return brief[n.Length..].Trim(':', ' ');
                return brief;
        }
    }

    /// 改了多少行：(+新增, −删除)，不是改文件的工具为空
    public static (int Added, int Removed)? DiffStat(ChatItem item)
    {
        var input = item.Input;
        static int Lines(JsonNode? value) => J.AsString(value) is string text && text.Length > 0 ? text.Split('\n').Length : 0;
        return item.Name switch
        {
            "Edit" => (Lines(input.Get("new_string")), Lines(input.Get("old_string"))),
            "MultiEdit" => input.Arr("edits").Items().Aggregate((0, 0), (acc, e) => (acc.Item1 + Lines(e.Get("new_string")), acc.Item2 + Lines(e.Get("old_string")))),
            "Write" => (Lines(input.Get("content")), 0),
            _ => null,
        };
    }

    public static string Basename(string path) => path.Split('/', '\\').LastOrDefault(s => s.Length > 0) ?? path;

    /// 模型 id → 人话（claude-opus-5-5 → Opus 5.5）
    public static string ModelName(string? id)
    {
        if (string.IsNullOrEmpty(id)) return "";
        var parts = id.Replace("claude-", "").Split('-');
        var family = parts[0];
        if (family.Length == 0) return id;
        var version = string.Join(".", parts.Skip(1).TakeWhile(p => p.Length <= 2 && p.All(char.IsDigit)));
        return char.ToUpperInvariant(family[0]) + family[1..] + (version.Length == 0 ? "" : " " + version);
    }
}
