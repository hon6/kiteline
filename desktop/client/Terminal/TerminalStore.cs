using System.Text.Json.Nodes;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using Kiteline.Model;
using Kiteline.Net;
using static Kiteline.Lang;

namespace Kiteline.Terminal;

/// 会话里开着的一个终端：开在会话所在的电脑上（Remote-SSH 的会话就是那台服务器），目录是会话的工作目录（见 watcher 的 term）
public sealed record TermInfo(string Id, string Shell, string Cwd, double CreatedAt)
{
    public static TermInfo? Parse(JsonNode? n) =>
        n.Str("term") is string id ? new TermInfo(id, n.Str("shell") ?? "", n.Str("cwd") ?? "", n.Num("createdAt") ?? 0) : null;

    /// 标签上的名字：shell 名（zsh、bash、pwsh）
    public string Name => Shell.Replace(".exe", "") is { Length: > 0 } name ? name : "shell";
}

/// 显示某个终端的视图：收输出
public interface ITermSink
{
    void Feed(byte[] bytes, int offset);
    /// 接不上了（中间漏了一段，电脑上留的输出也不够补）：清屏，接着从电脑上留的那段重放
    void Restart();
}

/// 会话里的终端（同 iPhone / Mac 版 TerminalStore）：开、关、按键、改大小经 /api/term 发给后台；输出从实时连接来
/// （term 事件，seq = 这段在整条输出里的字节位置），按位置接起来喂给正在显示它的视图，漏了就向后台要最近的输出补上
public sealed partial class TerminalStore : ObservableObject
{
    public static TerminalStore Shared { get; } = new();

    readonly Dictionary<string, List<TermInfo>> lists = new();
    readonly Dictionary<string, string> selected = new();
    readonly HashSet<string> opening = [];
    readonly Dictionary<string, Feed> feeds = new();
    readonly Dictionary<string, (string Key, List<byte> Bytes)> outbox = new();
    readonly HashSet<string> sending = [];
    readonly Dictionary<string, CancellationTokenSource> resizes = new();

    /// 终端列表、选中、正在开有变化（面板和按钮角标跟着重画）
    [ObservableProperty] int revision;

    sealed class Feed(string key, ITermSink sink)
    {
        public readonly string Key = key;
        public readonly ITermSink Sink = sink;
        /// 下一个要的字节位置；-1 = 还在拉后台留的那段，期间到的先攒着
        public long Next = -1;
        public readonly List<(long Seq, byte[] Bytes)> Early = [];
    }

    static Api Api => AppModel.Shared.Api;

    public IReadOnlyList<TermInfo>? List(string key) => lists.GetValueOrDefault(key);
    public string? Selected(string key) => selected.GetValueOrDefault(key);
    public bool IsOpening(string key) => opening.Contains(key);

    /// 角标：拉过列表的用手里的（刚开、刚关立刻变），没拉过的用后台报的
    public int Count(SessionInfo s) => lists.TryGetValue(s.Key, out var list) ? list.Count : s.Terminals;

    public void Select(string key, string id)
    {
        selected[key] = id;
        Revision++;
    }

    static Dictionary<string, string> Q(string key) => new() { ["key"] = key };

    // MARK: 开、关、列

    public async Task Refresh(string key)
    {
        try
        {
            var reply = await Api.Post("/api/term", new { op = "list" }, Q(key));
            var terms = reply.Arr("terms").Items().Select(TermInfo.Parse).OfType<TermInfo>().ToList();
            lists[key] = terms;
            if (!terms.Any(t => t.Id == selected.GetValueOrDefault(key)))
            {
                if (terms.Count > 0) selected[key] = terms[^1].Id; else selected.Remove(key);
            }
            Revision++;
        }
        catch (Exception e)
        {
            AppModel.Shared.Flash(e.Message);
        }
    }

    public async Task<TermInfo?> Open(string key, int cols = 80, int rows = 24)
    {
        if (!opening.Add(key)) return null;
        Revision++;
        try
        {
            var reply = await Api.Post("/api/term", new { op = "open", cols, rows }, Q(key));
            if (TermInfo.Parse(reply?["term"]) is not TermInfo term) return null;
            var list = lists.TryGetValue(key, out var have) ? have : lists[key] = [];
            if (!list.Any(t => t.Id == term.Id)) list.Add(term);
            selected[key] = term.Id;
            return term;
        }
        catch (Exception e)
        {
            AppModel.Shared.Flash(e.Message);
            return null;
        }
        finally
        {
            opening.Remove(key);
            Revision++;
        }
    }

    public async Task Close(string key, string id)
    {
        try
        {
            await Api.Post("/api/term", new { op = "close", term = id }, Q(key));
            Remove(key, id);
        }
        catch (Exception e)
        {
            AppModel.Shared.Flash(e.Message);
            await Refresh(key);
        }
    }

    void Remove(string key, string id)
    {
        feeds.Remove(id);
        outbox.Remove(id);
        if (!lists.TryGetValue(key, out var list)) return;
        var index = list.FindIndex(t => t.Id == id);
        if (index < 0) return;
        list.RemoveAt(index);
        if (selected.GetValueOrDefault(key) == id)
        {
            if (list.Count > 0) selected[key] = list[Math.Min(index, list.Count - 1)].Id; else selected.Remove(key);
        }
        Revision++;
    }

    // MARK: 输出

    /// 视图出现：先要后台留的最近一段输出把画面接上，之后实时的按位置接着喂
    public void Attach(string key, string id, ITermSink sink)
    {
        if (feeds.TryGetValue(id, out var feed) && feed.Sink == sink) return;
        feeds[id] = new Feed(key, sink);
        _ = Resync(id);
    }

    public void Detach(string id, ITermSink sink)
    {
        if (feeds.TryGetValue(id, out var feed) && feed.Sink == sink) feeds.Remove(id);
    }

    /// 实时连接上的 term / term_exit
    public void Receive(string name, JsonNode? json)
    {
        if (!Dispatcher.UIThread.CheckAccess()) { Dispatcher.UIThread.Post(() => Receive(name, json)); return; }
        if (json.Str("term") is not string id || json.Str("key") is not string key) return;
        if (name == "term_exit") { Remove(key, id); return; }
        if (!feeds.TryGetValue(id, out var feed) || json.Num("seq") is not double seq || json.Str("data") is not string data) return;
        byte[] bytes;
        try { bytes = Convert.FromBase64String(data); } catch (FormatException) { return; }
        if (feed.Next < 0) feed.Early.Add(((long)seq, bytes));
        else Take(feed, id, (long)seq, bytes);
    }

    void Take(Feed feed, string id, long seq, byte[] bytes)
    {
        var end = seq + bytes.Length;
        if (end <= feed.Next) return;   // 重放过的
        if (seq > feed.Next)
        {
            // 中间漏了一段（实时连接断过）：向后台要
            feed.Next = -1;
            feed.Early.Clear();
            feed.Early.Add((seq, bytes));
            _ = Resync(id);
            return;
        }
        feed.Sink.Feed(bytes, (int)(feed.Next - seq));
        feed.Next = end;
    }

    /// 拉后台留的最近一段输出：接得上就补上缺的，接不上清屏重放
    async Task Resync(string id)
    {
        if (!feeds.TryGetValue(id, out var feed)) return;
        try
        {
            var reply = await Api.Post("/api/term", new { op = "read", term = id }, Q(feed.Key));
            if (!feeds.TryGetValue(id, out var still) || still != feed || reply.Num("seq") is not double startValue) return;
            var bytes = Convert.FromBase64String(reply.Str("data") ?? "");
            var start = (long)startValue;
            var have = feed.Next;
            if (have >= start && have <= start + bytes.Length) feed.Sink.Feed(bytes, (int)(have - start));
            else
            {
                if (have >= 0) feed.Sink.Restart();
                feed.Sink.Feed(bytes, 0);
            }
            feed.Next = start + bytes.Length;
            var early = feed.Early.OrderBy(e => e.Seq).ToList();
            feed.Early.Clear();
            foreach (var (seq, chunk) in early) Take(feed, id, seq, chunk);
        }
        catch (Exception e)
        {
            feed.Next = Math.Max(feed.Next, 0);
            if (e.Message.Contains("终端已关闭")) Remove(feed.Key, id);
        }
    }

    /// 实时连接断过又连上：正在看的终端都补一次
    public void Reconnected()
    {
        if (!Dispatcher.UIThread.CheckAccess()) { Dispatcher.UIThread.Post(Reconnected); return; }
        foreach (var (id, feed) in feeds.ToList())
            if (feed.Next >= 0) _ = Resync(id);
    }

    // MARK: 按键、大小

    /// 按键按顺序发：上一批还没回来时新按的攒着，回来了一起发（不会乱序，打字快也不会一键一个请求）
    public void Send(string key, string id, byte[] bytes)
    {
        if (!outbox.TryGetValue(id, out var pending)) outbox[id] = pending = (key, []);
        pending.Bytes.AddRange(bytes);
        if (!sending.Add(id)) return;
        _ = Pump(id);
    }

    async Task Pump(string id)
    {
        try
        {
            while (outbox.TryGetValue(id, out var batch) && batch.Bytes.Count > 0)
            {
                var data = Convert.ToBase64String(batch.Bytes.ToArray());
                batch.Bytes.Clear();
                try
                {
                    await Api.Post("/api/term", new { op = "input", term = id, data, base64 = true }, Q(batch.Key));
                }
                catch (Exception e)
                {
                    outbox.Remove(id);
                    AppModel.Shared.Flash(e.Message);
                    if (e.Message.Contains("终端已关闭")) Remove(batch.Key, id);
                    return;
                }
            }
        }
        finally
        {
            sending.Remove(id);
        }
    }

    /// 视图大小变了：停手 0.15 秒再告诉后台（拖面板高度时不连发）
    public void Resize(string key, string id, int cols, int rows)
    {
        if (resizes.Remove(id, out var old)) old.Cancel();
        var cancel = resizes[id] = new CancellationTokenSource();
        _ = Task.Run(async () =>
        {
            try { await Task.Delay(150, cancel.Token); } catch (TaskCanceledException) { return; }
            try { await Api.Post("/api/term", new { op = "resize", term = id, cols, rows }, Q(key)); } catch { }
        });
    }
}
