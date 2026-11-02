using System.Diagnostics;
using System.Text.Json.Nodes;
using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using Kiteline.Net;

namespace Kiteline.Model;

/// 检查更新（同 Mac 版 Updater）：查新版本、下载、安装都由本机的 Kiteline 后台做（desktop/kiteline/updater.py），
/// 客户端只看状态、发指令：有新版本 → 右上角绿色箭头；下载时看进度；装好后提示重启，重启时后台把客户端也一起关掉再打开。
/// 后台说该弹了（prompt：发现新版本，没勾「此版本不再提示」，上次弹过已过 24 小时）就自动弹出更新弹窗；
/// 配对过的手机上的 Kiteline 比 App Store 旧时（phones）同样弹一次「手机端有新版本」
public sealed partial class UpdateState : ObservableObject
{
    public static UpdateState Shared { get; } = new();

    /// idle / checking / none / available / downloading / installing / ready / restarting / error
    [ObservableProperty] string phase = "idle";
    [ObservableProperty] string version = "";
    [ObservableProperty] string current = "";
    [ObservableProperty] string notes = "";
    [ObservableProperty] long size;
    [ObservableProperty] long received;
    [ObservableProperty] string error = "";
    [ObservableProperty] bool supported;
    [ObservableProperty] string reason = "";
    [ObservableProperty] string page = "";
    /// 落后几个版本
    [ObservableProperty] int behind;
    /// 「此版本不再提示」「弹过了」按它记（windows:1.0.22）
    [ObservableProperty] string key = "";
    [ObservableProperty] bool skipped;

    /// 落后的这几版各自的更新内容（新的在前）；取不到就只有新版本这一版
    public IReadOnlyList<ReleaseNote> Releases { get; private set; } = [];
    /// 配对过的手机里还是旧版本的；都是新的就是 null
    public PhoneOffer? Phones { get; private set; }

    public sealed record ReleaseNote(string Version, string Date, string Notes);
    public sealed record PhoneDevice(string Name, string Version);
    public sealed record PhoneOffer(string Version, string Notes, IReadOnlyList<PhoneDevice> Devices, string Key, bool Skipped);

    /// 该自动弹了：电脑端自己的新版本 / 手机端的新版本
    public event Action? PromptOwn;
    public event Action? PromptPhones;
    /// 这次运行已经弹过的（等后台记下「弹过了」之前别重复弹）
    readonly HashSet<string> prompted = [];
    /// 更新弹窗开着（UpdateDialog 设）：这时轮到手机的就等它关了、下一轮再弹，不同时弹两个
    public bool DialogOpen { get; set; }

    /// 右上角要不要显示绿色箭头
    public bool Visible => Phase is "available" or "downloading" or "installing" or "ready" || (Phase == "error" && Version.Length > 0);
    public bool Busy => Phase is "downloading" or "installing";
    public double Progress => Size > 0 ? Math.Min(1, Received / (double)Size) : 0;

    /// 下载装好了：弹「重启以完成更新」
    public event Action? Ready;

    Api? api;
    bool registered;
    DispatcherTimer? timer;

    public void Start(Api api)
    {
        this.api = api;
        timer = new DispatcherTimer(TimeSpan.FromSeconds(60), DispatcherPriority.Background, (_, _) => _ = Poll());
        timer.Start();
        _ = Poll();
    }

    async Task Poll()
    {
        if (api is null) return;
        try
        {
            JsonNode? reply;
            if (!registered)
            {
                // 报上自己：从托盘、控制台点重启时，后台也会把客户端关掉、换完文件再打开
                reply = await api.Post("/api/desktop/update/client", new JsonObject
                {
                    ["pid"] = Environment.ProcessId, ["exe"] = Environment.ProcessPath ?? "", ["args"] = new JsonArray(),
                });
                registered = true;
            }
            else reply = await api.Get("/api/desktop/update");
            Apply(reply);
        }
        catch
        {
            // 后台是旧版（没有这些接口）或者没连上：不显示
            registered = false;
        }
    }

    /// 自测截图用：直接给一份状态
    public void Inject(JsonNode? n) => Apply(n);

    void Apply(JsonNode? n)
    {
        if (n is null || n.Str("phase") is not string next) return;
        var before = Phase;
        Version = n.Str("version") ?? "";
        Current = n.Str("current") ?? "";
        Notes = n.Str("notes") ?? "";
        Size = (long)(n.Num("size") ?? 0);
        Received = (long)(n.Num("received") ?? 0);
        Error = n.Str("error") ?? "";
        Supported = n.Truthy("supported");
        Reason = n.Str("reason") ?? "";
        Page = n.Str("page") ?? "";
        Behind = (int)(n.Num("behind") ?? 0);
        Key = n.Str("key") ?? "";
        Skipped = n.Truthy("skipped");
        Releases = (n.Arr("releases") ?? []).Select(r => new ReleaseNote(r.Str("version") ?? "", r.Str("date") ?? "",
            ((Lang.IsEnglish ? r.Str("notesEn") : null) is { Length: > 0 } en ? en : r.Str("notes") ?? "").Trim()))
            .Where(r => r.Version.Length > 0 && r.Notes.Length > 0).ToList();
        var phones = n.Obj("phones");
        Phones = phones is null ? null : new PhoneOffer(phones.Str("version") ?? "", phones.Str("notes") ?? "",
            (phones.Arr("devices") ?? []).Select(d => new PhoneDevice(d.Str("name") ?? "", d.Str("version") ?? "")).ToList(),
            phones.Str("key") ?? "", phones.Truthy("skipped"));
        Phase = next;
        OnPropertyChanged(nameof(Releases));
        OnPropertyChanged(nameof(Phones));
        OnPropertyChanged(nameof(Progress));
        OnPropertyChanged(nameof(Visible));
        if (next == "ready" && before != "ready") Ready?.Invoke();
        // 后台说该弹了：弹一次、报「弹过了」（24 小时内不再弹）。自己的和手机的同时到时先弹自己的，手机的等下一轮
        if (next == "available" && n.Truthy("prompt") && Key.Length > 0 && prompted.Add(Key))
        {
            _ = Prompted(Key);
            PromptOwn?.Invoke();
        }
        else if (Phones is { } offer && phones!.Truthy("prompt") && offer.Key.Length > 0 && !DialogOpen && prompted.Add(offer.Key))
        {
            _ = Prompted(offer.Key);
            PromptPhones?.Invoke();
        }
        if (next == "restarting") Quit();
        // 下载、安装中：半秒看一次进度
        if (timer is not null) timer.Interval = Busy ? TimeSpan.FromMilliseconds(500) : TimeSpan.FromSeconds(60);
    }

    async Task Send(string path, JsonObject? body = null)
    {
        if (api is null) return;
        try { Apply(await api.Post(path, body ?? new JsonObject())); } catch (Exception e) { AppModel.Shared.Flash(e.Message); }
        await Poll();
    }

    public Task Check() => Send("/api/desktop/update/check");
    public Task Begin() => Send("/api/desktop/update/start");
    public Task Cancel() => Send("/api/desktop/update/cancel");
    public Task Later() => Send("/api/desktop/update/later");
    /// 勾 / 取消「此版本不再提示」（key：自己的 Key 或 Phones.Key）
    public Task Skip(string key, bool on) => Send("/api/desktop/update/skip", new JsonObject { ["key"] = key, ["on"] = on });
    /// 弹过了（自动弹的、自己点开的都算）：24 小时内不再自动弹
    public Task Prompted(string key) => Send("/api/desktop/update/prompted", new JsonObject { ["key"] = key });

    /// 立即重启：后台起一个小脚本，等这边和后台都退出、换上新文件、再把两个都打开
    public async Task<bool> Restart()
    {
        if (api is null) return false;
        try
        {
            var reply = await api.Post("/api/desktop/update/restart", new JsonObject
            {
                ["client"] = new JsonObject { ["pid"] = Environment.ProcessId, ["exe"] = Environment.ProcessPath ?? "", ["args"] = new JsonArray() },
            });
            if (!reply.Truthy("ok")) { Error = reply.Str("error") ?? ""; Phase = "error"; return false; }
        }
        catch (Exception e) { AppModel.Shared.Flash(e.Message); return false; }
        Phase = "restarting";
        Quit();
        return true;
    }

    bool quitting;

    void Quit()
    {
        if (quitting) return;
        quitting = true;
        Prefs.Save();
        // 稍等一下再退（让后台先收到回复），脚本会在换完文件后重新打开客户端
        DispatcherTimer.RunOnce(() =>
        {
            if (Application.Current?.ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop) desktop.Shutdown();
            else Environment.Exit(0);
        }, TimeSpan.FromMilliseconds(300));
    }

    /// 自动更新用不了（开发版、没有写入权限……）：打开官网下载页
    public void OpenPage()
    {
        if (Page.Length == 0) return;
        try { Process.Start(new ProcessStartInfo(Page) { UseShellExecute = true }); } catch { }
    }
}
