using System.Text.Json.Nodes;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 会话菜单「分享只读链接」（同 iOS / Mac 版 GuestShareSheet）：生成一个局域网网址，同一网络里的人用浏览器就能看这个会话（对话和步骤，只读）。
/// 页面和内容都由电脑直接给（见 desktop/kiteline/guest.py），不经过任何服务器；可选有效期，随时停止分享
public static class GuestShare
{
    static Net.Api Api => AppModel.Shared.Api;

    public static void Open(string key) => NavSheet.Open(L("分享只读链接"), sheet => NavSheet.Load(async () =>
    {
        var box = new StackPanel { Spacing = 14, Margin = new Avalonia.Thickness(18, 4, 18, 18) };
        JsonNode? current = null;
        try { current = (await Api.Get("/api/share", new Dictionary<string, string> { ["key"] = key })).Arr("shares").Items().FirstOrDefault(); }
        catch (Exception e) { box.Children.Add(Ui.Text(L("无法读取分享状态：%@", e.Message), 12, color: "Red", lines: 3)); }
        Draw(box, key, current);
        return NavSheet.Scroll(box);
    }), 480, 400);

    static void Draw(StackPanel box, string key, JsonNode? share)
    {
        box.Children.Clear();
        box.Children.Add(Ui.Text(L("生成一个局域网网址，和这台电脑在同一网络（Wi-Fi）里的人用浏览器就能查看这个会话，不用装 Kiteline：对话和执行的步骤，不含思考过程、图片和关键信息。会话有进展时，对方的页面自动更新。"), 12, color: "Text2", lines: 5));
        var status = Ui.Text("", 12, color: "Red", lines: 3);
        if (share is null)
        {
            var hours = "24";
            box.Children.Add(Ui.V(8, Ui.Text(L("有效期"), 13, FontWeight.Medium),
                new LookSegmented([("1", L("1 小时")), ("24", L("24 小时")), ("168", L("7 天"))], hours, value => hours = value)));
            GlassButton? create = null;
            create = new GlassButton(L("生成链接"), null, async () =>
            {
                create!.IsEnabled = false;
                status.Text = "";
                try
                {
                    var made = await Api.Post("/api/share", new Dictionary<string, object> { ["key"] = key, ["hours"] = int.Parse(hours) });
                    if (made.Str("url") is { } url) SessionMenu.Copy(url);   // 生成了就顺手复制好
                    Draw(box, key, made);
                }
                catch (Exception e) { status.Text = e.Message; create.IsEnabled = true; }
            }, prominent: true, height: 32);
            box.Children.Add(Ui.H(10, create, status.Shrink()));
        }
        else
        {
            var url = share.Str("url") ?? "";
            var link = Ui.Text(url, 12, lines: 3);
            link.FontFamily = Look.Mono;
            link.TextWrapping = TextWrapping.Wrap;
            box.Children.Add(new Border { Padding = new Avalonia.Thickness(10), CornerRadius = new Avalonia.CornerRadius(8), BorderThickness = new Avalonia.Thickness(1), Child = link }
                .Res(Border.BackgroundProperty, "AccentFill14").Res(Border.BorderBrushProperty, "AccentEdge32"));
            var expires = share.Num("expires") ?? 0;
            box.Children.Add(Ui.Text(L("有效至 %@", DateTimeOffset.FromUnixTimeSeconds((long)expires).LocalDateTime.ToString("g")), 12, color: "Text2"));
            GlassButton? stop = null;
            stop = new GlassButton(L("停止分享"), null, async () =>
            {
                stop!.IsEnabled = false;
                status.Text = "";
                try
                {
                    await Api.Post("/api/share/stop", new Dictionary<string, object> { ["id"] = share.Str("id") ?? "" });
                    Draw(box, key, null);
                }
                catch (Exception e) { status.Text = e.Message; stop.IsEnabled = true; }
            }, height: 32);
            box.Children.Add(Ui.H(10, new GlassButton(L("复制链接"), "doc.on.doc", () => SessionMenu.Copy(url), prominent: true, height: 32), stop, status.Shrink()));
        }
        box.Children.Add(Ui.Text(L("页面和内容直接由你的电脑提供，不经过任何服务器；电脑关机或不在这个网络时打不开。拿到网址的人都能查看，请只发给信任的人；停止分享后立即失效。"), 11, color: "Text2", lines: 4));
    }
}
