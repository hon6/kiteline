using System.Globalization;
using System.Text.Json.Nodes;
using Kiteline.Net;
using static Kiteline.Lang;

namespace Kiteline.Model;

// 会话之间的消息（Claude Code 的 SendMessage），同 iOS 版 Model/Peers.swift：
// - 对话里：发出的那步（tool SendMessage）和收到的那条（event）都带 peer，画成「致 / 来自某会话」的信件
// - 实时事件 peers / 接口 /api/peers：一条条往来（谁发给谁、什么时候发、对方什么时候读到），
//   给侧栏会话列表上飞的纸鸢、头像两侧滚动的虚线用

/// 对话项上的往来信息：Dir = out 发出 / in 收到；Session 是对方的会话 id（同一台电脑上，对不上时为空）
public sealed record PeerInfo(string? Dir, string? To, string? Name, string? Session, string? Summary, string? Text, string? Body, string? MsgId)
{
    public bool Outgoing => Dir != "in";

    public static PeerInfo? Parse(JsonNode? n) => n is JsonObject
        ? new(n.Str("dir"), n.Str("to"), n.Str("name"), n.Str("session"), n.Str("summary"), n.Str("text"), n.Str("body"), n.Str("msgId"))
        : null;
}

/// 一条往来：From / To 是会话 key（来源#会话 id）
public sealed record PeerLink(string Id, string? From, string? To, string? FromName, string? ToName, string? FromTitle, string? ToTitle,
                              string? Summary, string? Text, double? SentAt, double? ReadAt, bool? Ok, string? Was)
{
    public double Stamp => SentAt ?? ReadAt ?? 0;

    public static PeerLink? Parse(JsonNode? n) => n.Str("id") is string id
        ? new(id, n.Str("from"), n.Str("to"), n.Str("fromName"), n.Str("toName"), n.Str("fromTitle"), n.Str("toTitle"),
              n.Str("summary"), n.Str("text"), n.Num("sentAt"), n.Num("readAt"), n.Bool("ok"), n.Str("was"))
        : null;
}

/// 列表上正在飞的一只纸鸢（发出一条消息时放一次）
public sealed record PeerFlight(string Id, string? From, string? To, string ToLabel, DateTime Start)
{
    public const double Duration = 1.5;
}

/// 一个方向上的往来：From 发给 To 的最近一次
public sealed record PeerDirection(string From, string To, double Last);

/// 用户可选的几样效果（设置 → 通用 → 会话之间的消息），键和 iOS / Mac 一样
public static class PeerPrefs
{
    public const string FlightsKey = "peerFlights", LanesKey = "peerLanes", CardsKey = "peerCards", RopesKey = "peerRopes";
    public static bool Flights => Prefs.Bool(FlightsKey, true);
    public static bool Lanes => Prefs.Bool(LanesKey, true);
    public static bool Cards => Prefs.Bool(CardsKey, true);
    /// 分屏里同一封信的两张信件之间的绳子（见 Views/PeerRopes.cs）
    public static bool Ropes => Prefs.Bool(RopesKey, true);
    public static event Action? Changed;

    public static void Set(string key, bool on)
    {
        Prefs.Set(key, on);
        Changed?.Invoke();
    }
}

/// 往来的总账：后台推来的都记在这（最近两天的），放动画的队列也在这。只在界面线程用
public sealed class PeerBoard
{
    public static PeerBoard Shared { get; } = new();

    public Dictionary<string, PeerLink> Links { get; } = new();
    public List<PeerFlight> Flights { get; } = new();
    /// 收信那一行闪一下（对方读到了）：会话 key → 什么时候
    public Dictionary<string, DateTime> Pulses { get; } = new();
    /// 发出那一步的工具调用 id → 正式的往来 id（对话里的信按工具调用找状态）
    readonly Dictionary<string, string> aliases = new();

    /// 有变化（新往来、纸鸢起飞、落下）：侧栏、对话里的信重画
    public event Action? Changed;

    /// 自测截图逐帧看纸鸢：环境变量 KITELINE_DEMO_FLIGHT=0～1.4，纸鸢停在这个位置、不飞走（同 iOS 截图版的 TARS_DEMO_FLIGHT）
    public static readonly double? Frozen =
        double.TryParse(Environment.GetEnvironmentVariable("KITELINE_DEMO_FLIGHT"), NumberStyles.Float, CultureInfo.InvariantCulture, out var f) ? f : null;

    /// 实时事件 peers / 接口 /api/peers 的一批；backfill = 刚连上补齐的旧往来：只记，不放动画
    public void Receive(JsonNode? json, bool backfill = false)
    {
        backfill |= json.Bool("backfill") == true;
        var now = Format.NowMs;
        foreach (var link in json.Arr("links").Items().Select(PeerLink.Parse).OfType<PeerLink>())
        {
            var known = Links.ContainsKey(link.Id);
            if (link.Was is string was)
            {
                if (Links.Remove(was)) known = true;
                if (was.StartsWith("t:")) aliases[was[2..]] = link.Id;
            }
            Links.TryGetValue(link.Id, out var before);
            Links[link.Id] = link;
            if (backfill) continue;
            // 刚发出的（半分钟内）：放一只纸鸢；对方刚读到：收信那行闪一下
            if (!known && link.SentAt is double sent && now - sent < 30_000 && PeerPrefs.Flights) Fly(link);
            if (before?.ReadAt is null && link.ReadAt is double read && now - read < 30_000 && link.To is string to)
            {
                Pulses[to] = DateTime.UtcNow;
                Later(2, () => { if (Pulses.TryGetValue(to, out var at) && (DateTime.UtcNow - at).TotalSeconds >= 1.9) { Pulses.Remove(to); Changed?.Invoke(); } });
            }
        }
        var cutoff = now - 2 * 86_400_000;
        if (Links.Count > 400)
            foreach (var old in Links.Where(kv => kv.Value.Stamp < cutoff).Select(kv => kv.Key).ToList()) Links.Remove(old);
        Changed?.Invoke();
    }

    /// 刚连上：拉最近一天的往来（后台旧、没有这个接口时就算了）
    public async Task Load(Api api)
    {
        try { Receive(await api.Get("/api/peers"), backfill: true); }
        catch (Exception) { }
    }

    /// 发出那一步（工具调用 id）对应的往来
    public PeerLink? LinkFor(string? toolId, string? msgId)
    {
        if (msgId is not null && Links.TryGetValue(msgId, out var byMsg)) return byMsg;
        if (toolId is null) return null;
        if (aliases.TryGetValue(toolId, out var id) && Links.TryGetValue(id, out var byAlias)) return byAlias;
        return Links.GetValueOrDefault("t:" + toolId);
    }

    /// 某条往来之后，对方有没有回过来
    public PeerLink? Reply(PeerLink link) =>
        link.From is null || link.To is null ? null
            : Links.Values.Where(l => l.From == link.To && l.To == link.From && l.Stamp > link.Stamp).MinBy(l => l.Stamp);

    /// 最近 window 毫秒内的往来按方向归并（谁发给谁一条）：一个方向一条虚线，新的在前
    public List<PeerDirection> RecentDirections(double window)
    {
        var now = Format.NowMs;
        return Links.Values.Where(l => now - l.Stamp < window && l.From is not null && l.To is not null && l.From != l.To)
            .GroupBy(l => (l.From!, l.To!))
            .Select(g => new PeerDirection(g.Key.Item1, g.Key.Item2, g.Max(l => l.Stamp)))
            .OrderByDescending(d => d.Last).ToList();
    }

    void Fly(PeerLink link)
    {
        var flight = new PeerFlight(link.Id + "-" + Guid.NewGuid().ToString("N")[..4], link.From, link.To,
                                    link.ToTitle ?? link.ToName ?? L("其他会话"), DateTime.UtcNow);
        Flights.Add(flight);
        if (Frozen is null) Later(PeerFlight.Duration + 2.2, () => { Flights.Remove(flight); Changed?.Invoke(); });
    }

    static void Later(double seconds, Action action) =>
        Avalonia.Threading.DispatcherTimer.RunOnce(action, TimeSpan.FromSeconds(seconds));
}
