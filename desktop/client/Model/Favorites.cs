using System.Text.Json.Nodes;
using CommunityToolkit.Mvvm.ComponentModel;
using static Kiteline.Lang;

namespace Kiteline.Model;

/// 一条收藏（同 iOS 版 FavoriteItem）：收藏时那条消息的文字和图（图在 /api/favorites/media?ref=）
public sealed record FavoriteItem(string Id, string Key, string ItemId, string Title, string? Machine, string Who, string? Speaker, string? Agent,
                                  double? Ts, double At, string? Text, IReadOnlyList<ChatImage> Images)
{
    public const string MediaPath = "/api/favorites/media";
    public static Dictionary<string, string> MediaQuery(string reference) => new() { ["key"] = "favorites", ["ref"] = reference };

    /// 我发的（显示自己的名字）
    public bool Mine => Who == "me";

    public static FavoriteItem? Parse(JsonNode? n)
    {
        if (n is null || n.Str("key") is not string key || n.Str("itemId") is not string itemId) return null;
        return new FavoriteItem(n.Str("id") ?? Guid.NewGuid().ToString(), key, itemId, n.Str("title") ?? "",
                                n.Str("machine") is string machine ? Lang.Machine(machine) : null, n.Str("who") ?? "bot", n.Str("speaker"), n.Str("agent"),
                                n.Num("ts"), n.Num("at") ?? 0, n.Str("text"), n.Arr("images").Items().Select(ChatImage.Parse).OfType<ChatImage>().ToList());
    }
}

/// 我的收藏（同 iOS 版 Model/Favorites.swift）：对话里右键一条消息点「收藏」，那条的文字和图在电脑上存一份；
/// 各端连着同一台电脑，在手机上收藏的这里马上看得到。后台推 favorites 事件、/api/favorites 拉
public sealed partial class FavoriteState : ObservableObject
{
    public static FavoriteState Shared { get; } = new();

    [ObservableProperty] IReadOnlyList<FavoriteItem> items = [];
    HashSet<string> marks = [];

    /// 这条消息收藏过没有
    public bool Contains(string key, string itemId) => marks.Contains($"{key}|{itemId}");

    public void Apply(JsonNode? reply)
    {
        if (reply?.Get("items") is not JsonArray) return;
        Set(reply.Arr("items").Items().Select(FavoriteItem.Parse).OfType<FavoriteItem>().ToList());
    }

    void Set(IReadOnlyList<FavoriteItem> list)
    {
        marks = list.Select(i => $"{i.Key}|{i.ItemId}").ToHashSet();
        Items = list;
    }

    public async Task Refresh()
    {
        try { Apply(await AppModel.Shared.Api.Get("/api/favorites")); }
        catch (Exception) { }
    }

    /// 收藏一条消息：文字和图都存一份到电脑上（图取原图传过去：会话结束、记录清掉也还在）
    public async void Add(string key, ChatItem item, bool mine)
    {
        if (Contains(key, item.Id)) return;
        var model = AppModel.Shared;
        var text = (item.Text ?? "").Trim();
        var images = item.T == "agent_page" ? [] : item.Images ?? [];   // 网页（agent_page）只收藏标题和说明
        if (text.Length == 0 && images.Count == 0) return;
        var body = new JsonObject
        {
            ["key"] = key, ["itemId"] = item.Id, ["who"] = mine ? "me" : "bot",
            ["title"] = model.Session(key)?.Title ?? "",
        };
        if (text.Length > 0) body["text"] = text;
        if (item.Ts is double ts) body["ts"] = ts;
        if (!mine)
        {
            var agent = model.Session(key)?.Agent ?? Agents.DefaultId;
            body["agent"] = agent;
            body["speaker"] = model.Session(key)?.Speaker ?? "Claude";
        }
        try
        {
            if (images.Count > 0)
            {
                var list = new JsonArray();
                foreach (var image in images.Take(9))
                    list.Add(new JsonObject { ["data"] = Convert.ToBase64String(await model.Api.MediaData("/api/media", new Dictionary<string, string> { ["key"] = key, ["ref"] = image.Ref })) });
                body["images"] = list;
            }
            Apply(await model.Api.Post("/api/favorites/add", body));
            model.Flash(L("已收藏"));
        }
        catch (Exception e) { model.Flash(e.Message); }
    }

    /// 取消收藏：对话里按消息取消
    public void Remove(string key, string itemId)
    {
        Set(Items.Where(i => !(i.Key == key && i.ItemId == itemId)).ToList());
        Request(new JsonObject { ["key"] = key, ["itemId"] = itemId });
        AppModel.Shared.Flash(L("已取消收藏"));
    }

    /// 收藏页里删一条
    public void Delete(string id)
    {
        Set(Items.Where(i => i.Id != id).ToList());
        Request(new JsonObject { ["ids"] = new JsonArray(id) });
    }

    async void Request(JsonObject body)
    {
        try { Apply(await AppModel.Shared.Api.Post("/api/favorites/delete", body)); }
        catch (Exception e)
        {
            AppModel.Shared.Flash(e.Message);
            await Refresh();
        }
    }

    /// 消息右键菜单里的「收藏 / 取消收藏」（菜单打开时才算，收藏过的显示取消）；没有文字、图的消息不给
    public (string Title, Action Run)? MenuAction(string key, ChatItem item, bool mine)
    {
        if (string.IsNullOrWhiteSpace(item.Text) && (item.Images?.Count ?? 0) == 0) return null;
        return Contains(key, item.Id) ? (L("取消收藏"), () => Remove(key, item.Id)) : (L("加入收藏"), () => Add(key, item, mine));
    }
}
