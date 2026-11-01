using System.Text.Json.Nodes;

namespace Kiteline.Model;

/// 会话来自哪个编程 agent：名字 + 单色标志（24×24 的 SVG 路径，同 KitelineKit/Shared/AgentMark.swift；表在 Agents.g.cs）
public sealed record AgentLayer(string D, double Opacity);

public sealed record AgentInfo(string Id, string Name, AgentLayer[] Layers, string? Spoken = null)
{
    /// 对话里怎么称呼它：「Claude 想使用 Bash」「中断 Codex」（Spoken 是插件给的称呼）
    public string Speaker => Spoken ?? Id switch
    {
        "claude-code" => "Claude",
        "copilot" => "Copilot",
        "gemini-cli" => "Gemini",
        "qwen-code" => "Qwen",
        "kimi-cli" => "Kimi",
        "deepseek-harness" => "DeepSeek",
        _ => Name,
    };

    /// 确认卡片要不要给「允许，且本会话不再询问」：DeepSeek Harness 的审批只有「允许这一次」
    public bool AllowsAlways => Id != "deepseek-harness";
}

public static partial class Agents
{
    /// 没标 agent 的会话都算 Claude Code
    public const string DefaultId = "claude-code";

    static Dictionary<string, AgentInfo>? byId;

    static readonly object gate = new();
    static Dictionary<string, AgentInfo> registered = [];

    public static AgentInfo Info(string? id)
    {
        var key = string.IsNullOrEmpty(id) ? DefaultId : id;
        byId ??= All.GroupBy(a => a.Id).ToDictionary(g => g.Key, g => g.First());
        if (byId.TryGetValue(key, out var info)) return info;
        lock (gate) if (registered.TryGetValue(key, out var plugin)) return plugin;
        return new AgentInfo(key, key, []);
    }

    /// 后台插件给的 agent（/api/state 的 agents：{id, name, speaker?, mark?}）：只补内置表里没有的，新 agent 不用为了标志发版。
    /// mark 是 24×24 的单色 SVG 路径：一条路径、[{d, opacity}] 或 {svg}
    public static void Register(IEnumerable<JsonNode> cards)
    {
        byId ??= All.GroupBy(a => a.Id).ToDictionary(g => g.Key, g => g.First());
        var next = new Dictionary<string, AgentInfo>();
        foreach (var card in cards)
        {
            if (card.Str("id") is not { Length: > 0 } id || card.Str("name") is not { Length: > 0 } name || byId.ContainsKey(id)) continue;
            var mark = card.Get("mark");
            AgentLayer[] layers = mark switch
            {
                JsonValue => card.Str("mark") is { Length: > 0 } d ? [new AgentLayer(d, 1)] : [],
                JsonArray list => list.Items().Select(l => l.Str("d") is { Length: > 0 } d ? new AgentLayer(d, l.Num("opacity") ?? 1) : null).OfType<AgentLayer>().ToArray(),
                JsonObject => (mark.Str("svg") ?? mark.Str("d")) is { Length: > 0 } d ? [new AgentLayer(d, 1)] : [],
                _ => Array.Empty<AgentLayer>(),
            };
            next[id] = new AgentInfo(id, name, layers.Where(l => l.D.Length < 20_000).Take(8).ToArray(), card.Str("speaker") is { Length: > 0 } s ? s : null);
        }
        lock (gate) registered = next;
    }
}
