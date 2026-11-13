using System.Net;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json.Nodes;
using Kiteline.Model;
using static Kiteline.Lang;

namespace Kiteline.Net;

/// 本机的 Kiteline 后台（desktop/kiteline）在哪、主令牌是什么：读它的配置文件（同 Mac 主窗口连自己的服务）。
/// 配置目录：KITELINE_CONFIG_DIR（测试）/ Windows %APPDATA%\Kiteline / Linux $XDG_CONFIG_HOME/kiteline（默认 ~/.config/kiteline）。
/// 开发、自测可用 --server / --token（或环境变量 KITELINE_SERVER / KITELINE_TOKEN）直接指定
public sealed record LocalHost(Uri Base, string Token, string ConfigDir)
{
    public static string ConfigDirectory()
    {
        var overrideDir = Environment.GetEnvironmentVariable("KITELINE_CONFIG_DIR") ?? Environment.GetEnvironmentVariable("CCPULSE_CONFIG_DIR");
        if (!string.IsNullOrEmpty(overrideDir)) return overrideDir;
        if (OperatingSystem.IsWindows())
        {
            var appData = Environment.GetEnvironmentVariable("APPDATA");
            if (string.IsNullOrEmpty(appData)) appData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "AppData", "Roaming");
            return Path.Combine(appData, "Kiteline");
        }
        var xdg = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME");
        if (string.IsNullOrEmpty(xdg)) xdg = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config");
        return Path.Combine(xdg, "kiteline");
    }

    public static LocalHost? Find(string[] args)
    {
        string? Arg(string name)
        {
            var i = Array.IndexOf(args, name);
            return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
        }
        var dir = ConfigDirectory();
        var server = Arg("--server") ?? Environment.GetEnvironmentVariable("KITELINE_SERVER");
        var token = Arg("--token") ?? Environment.GetEnvironmentVariable("KITELINE_TOKEN");
        if (!string.IsNullOrEmpty(server) && !string.IsNullOrEmpty(token)) return new LocalHost(new Uri(server), token, dir);
        try
        {
            var config = J.Parse(File.ReadAllBytes(Path.Combine(dir, "config.json")));
            var mobile = config.Obj("mobile");
            var port = mobile.Int("port") ?? 8765;
            var key = mobile.Str("token");
            if (string.IsNullOrEmpty(key)) return null;
            // 明文 HTTP 只开在本机（同 Mac 版）
            return new LocalHost(new Uri($"http://127.0.0.1:{port}"), key, dir);
        }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }
}

public sealed class ApiError(string message, HttpStatusCode status, JsonNode? data) : Exception(message)
{
    public HttpStatusCode Status { get; } = status;
    public JsonNode? Body { get; } = data;
    public bool Unauthorized => Status == HttpStatusCode.Unauthorized;
}

/// 连不上后台（没在运行、端口不通）
public sealed class OfflineError(string message) : Exception(message);

/// 后台的接口：普通请求、图片、实时事件（同 iOS 版 MacAPI，只连本机，不用探路）
public sealed class Api
{
    public LocalHost Host { get; private set; }
    public Uri Base => Host.Base;
    public string Token => Host.Token;

    /// 重置配对令牌后换上后台给的新主令牌
    public void UseToken(string token) => Host = Host with { Token = token };

    readonly HttpClient client;
    /// 图片：单独一组连接，十几张图一起下时不占普通请求
    readonly HttpClient media;
    /// 实时事件流：不设总超时，靠保活判断断线
    readonly HttpClient stream;
    /// 要等后台把一件事做完才回应的请求（见 ActionPaths）：等得久一些
    readonly HttpClient action;
    /// 发消息、恢复会话、语音转写后发送、按键、回答提问、调整排队、关闭会话：后台要把这件事做完才回应，
    /// 后台通道卡一下、恢复会话、转写长录音都可能要十几秒；原来 12 秒就报「连接本机 Kiteline 超时」，其实那头还在送
    static readonly HashSet<string> ActionPaths = new() { "/api/send", "/api/resume", "/api/voice", "/api/key", "/api/answer", "/api/queue", "/api/close" };

    public Api(LocalHost host)
    {
        Host = host;
        client = Make(TimeSpan.FromSeconds(12));
        media = Make(TimeSpan.FromSeconds(45));
        action = Make(TimeSpan.FromSeconds(40));
        stream = Make(Timeout.InfiniteTimeSpan);
    }

    static HttpClient Make(TimeSpan timeout)
    {
        var handler = new SocketsHttpHandler { PooledConnectionLifetime = TimeSpan.FromMinutes(5), UseProxy = false, AutomaticDecompression = DecompressionMethods.All };
        return new HttpClient(handler) { Timeout = timeout };
    }

    public Uri Url(string path, IDictionary<string, string>? query = null)
    {
        var sb = new StringBuilder(path);
        if (query is { Count: > 0 })
        {
            sb.Append('?');
            sb.Append(string.Join("&", query.Select(kv => Uri.EscapeDataString(kv.Key) + "=" + Uri.EscapeDataString(kv.Value))));
        }
        return new Uri(Base, sb.ToString());
    }

    /// 图片等资源的地址（带令牌，给图片控件直接用）
    public Uri MediaUrl(string path, IDictionary<string, string>? query = null)
    {
        var q = new Dictionary<string, string>(query ?? new Dictionary<string, string>()) { ["t"] = Token };
        return Url(path, q);
    }

    HttpRequestMessage Request(HttpMethod method, Uri url)
    {
        var request = new HttpRequestMessage(method, url);
        request.Headers.Add("x-ccp-token", Token);
        request.Headers.Add("x-ccp-client", "desktop-app");
        // 后台发来的提示、状态这些字按界面语言给（同手机）
        request.Headers.Add("x-kiteline-lang", Lang.Current);
        return request;
    }

    async Task<byte[]> Send(HttpClient http, HttpRequestMessage request, CancellationToken cancel)
    {
        HttpResponseMessage response;
        try { response = await http.SendAsync(request, cancel); }
        catch (HttpRequestException e) { throw new OfflineError(L("无法连接本机 Kiteline：%@", e.Message)); }
        catch (TaskCanceledException) when (!cancel.IsCancellationRequested) { throw new OfflineError(L("连接本机 Kiteline 超时")); }
        using (response)
        {
            var data = await response.Content.ReadAsByteArrayAsync(cancel);
            if (response.IsSuccessStatusCode) return data;
            var json = J.Parse(data);
            var message = json.Str("error") ?? json.Str("message") ?? $"HTTP {(int)response.StatusCode}";
            throw new ApiError(message, response.StatusCode, json);
        }
    }

    public async Task<byte[]> Data(string path, IDictionary<string, string>? query = null, CancellationToken cancel = default) =>
        await Send(client, Request(HttpMethod.Get, Url(path, query)), cancel);

    public async Task<byte[]> MediaData(string path, IDictionary<string, string>? query = null, CancellationToken cancel = default) =>
        await Send(media, Request(HttpMethod.Get, Url(path, query)), cancel);

    public async Task<JsonNode?> Get(string path, IDictionary<string, string>? query = null, CancellationToken cancel = default) =>
        J.Parse(await Data(path, query, cancel));

    public async Task<JsonNode?> Post(string path, object? body = null, IDictionary<string, string>? query = null, CancellationToken cancel = default)
    {
        var request = Request(HttpMethod.Post, Url(path, query));
        var text = body is null ? "{}" : body is JsonNode node ? node.ToJsonString() : System.Text.Json.JsonSerializer.Serialize(body, JsonOptions.Default);
        request.Content = new StringContent(text, Encoding.UTF8, "application/json");
        var http = text.Length > 256_000 ? media : ActionPaths.Contains(path) ? action : client;
        return J.Parse(await Send(http, request, cancel));
    }

    /// 二进制回复的 POST（朗读合成的音频）
    public async Task<byte[]> PostData(string path, object? body = null, CancellationToken cancel = default)
    {
        var request = Request(HttpMethod.Post, Url(path));
        request.Content = new StringContent(System.Text.Json.JsonSerializer.Serialize(body ?? new { }, JsonOptions.Default), Encoding.UTF8, "application/json");
        return await Send(media, request, cancel);
    }

    /// 实时事件（SSE）：一条一条往外给 (事件名, 数据)。后台每 15 秒发一次保活，25 秒没动静就算断了
    public async IAsyncEnumerable<(string Event, string Data)> Events([EnumeratorCancellation] CancellationToken cancel)
    {
        var request = Request(HttpMethod.Get, Url("/api/events"));
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));
        HttpResponseMessage response;
        try { response = await stream.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancel); }
        catch (HttpRequestException e) { throw new OfflineError(L("无法连接本机 Kiteline：%@", e.Message)); }
        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                var body = J.Parse(await response.Content.ReadAsByteArrayAsync(cancel));
                throw new ApiError(body.Str("error") ?? $"HTTP {(int)response.StatusCode}", response.StatusCode, body);
            }
            await using var input = await response.Content.ReadAsStreamAsync(cancel);
            using var reader = new StreamReader(input, Encoding.UTF8);
            var name = "message";
            var data = new StringBuilder();
            while (!cancel.IsCancellationRequested)
            {
                using var idle = CancellationTokenSource.CreateLinkedTokenSource(cancel);
                idle.CancelAfter(TimeSpan.FromSeconds(25));
                string? line;
                try { line = await reader.ReadLineAsync(idle.Token); }
                catch (OperationCanceledException) when (!cancel.IsCancellationRequested) { throw new OfflineError(L("实时连接超时")); }
                if (line is null) yield break;
                if (line.Length == 0)
                {
                    if (data.Length > 0) yield return (name, data.ToString());
                    name = "message";
                    data.Clear();
                }
                else if (line.StartsWith(':')) { }   // 保活
                else if (line.StartsWith("event:")) name = line[6..].Trim();
                else if (line.StartsWith("data:"))
                {
                    if (data.Length > 0) data.Append('\n');
                    data.Append(line.Length > 5 && line[5] == ' ' ? line[6..] : line[5..]);
                }
            }
        }
    }
}

static class JsonOptions
{
    public static readonly System.Text.Json.JsonSerializerOptions Default = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };
}
