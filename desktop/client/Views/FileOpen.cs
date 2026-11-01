using Avalonia.Controls;
using Avalonia.Layout;
using Kiteline.Model;
using Kiteline.Net;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 打开消息里提到的电脑文件（同 iOS / Mac 版 FileOpener）：Claude 回复里的路径、手机发过来的附件。
/// 会话就在这台电脑上的直接用默认的程序打开（改了存回原处）；在别的机器上（Remote-SSH 来源）的先经 /api/download 取一份到临时目录再打开
public static class FileOpen
{
    public static async void Open(string key, string path, bool reveal = false)
    {
        var model = AppModel.Shared;
        var session = model.Session(key);
        var cwd = session?.Cwd ?? (model.PastMeta.TryGetValue(key, out var past) ? past.Cwd : null);
        if ((session?.SourceKind ?? (key.StartsWith("local") ? "local" : null)) == "local" && Local(path, cwd) is string local && File.Exists(local))
        {
            Launch(local);
            return;
        }
        var name = FileLinks.DisplayName(path);
        model.Flash(L("正在从电脑取回「%@」…", name));
        try
        {
            var query = new Dictionary<string, string> { ["key"] = key, ["path"] = path };
            if (cwd is not null) query["cwd"] = cwd;
            if (reveal) query["reveal"] = "1";
            var data = await model.Api.MediaData("/api/download", query);
            var dir = Path.Combine(Path.GetTempPath(), "Kiteline-" + Guid.NewGuid().ToString("N")[..8]);
            Directory.CreateDirectory(dir);
            var file = Path.Combine(dir, string.Concat(name.Split(Path.GetInvalidFileNameChars())) is { Length: > 0 } safe ? safe : "file");
            await File.WriteAllBytesAsync(file, data);
            Launch(file);
        }
        catch (ApiError e) when (e.Body.Bool("secret") == true)
        {
            // 名字像密钥、密码的文件（.env、私钥……）：先问一句（同项目文件页的「仍然查看」）
            if (await Dialogs.Confirm(L("「%@」可能包含密钥或密码，默认不传到手机。仍要取回吗？", name), L("仍然取回"))) Open(key, path, true);
        }
        catch (Exception e) { model.Flash(L("无法取回文件：%@", e.Message)); }
    }

    /// 群里发的文件（存在电脑上）：取一份到临时目录再用默认的程序打开
    public static async void OpenGroupFile(string groupId, GroupMedia file)
    {
        var model = AppModel.Shared;
        model.Flash(L("正在从电脑取回「%@」…", file.Name));
        try
        {
            var data = await model.Api.MediaData(GroupMedia.Path, new Dictionary<string, string> { ["id"] = groupId, ["ref"] = file.Ref });
            var dir = Path.Combine(Path.GetTempPath(), "Kiteline-" + Guid.NewGuid().ToString("N")[..8]);
            Directory.CreateDirectory(dir);
            var target = Path.Combine(dir, string.Concat(file.Name.Split(Path.GetInvalidFileNameChars())) is { Length: > 0 } safe ? safe : "file");
            await File.WriteAllBytesAsync(target, data);
            Launch(target);
        }
        catch (Exception e) { model.Flash(L("无法取回文件：%@", e.Message)); }
    }

    /// 本机路径：~/ 换成用户目录，相对路径按会话目录算
    static string? Local(string path, string? cwd)
    {
        if (path.StartsWith("~/")) return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), path[2..]);
        if (FileLinks.IsAbsolute(path)) return path;
        return cwd is null ? null : Path.Combine(cwd, path);
    }

    static void Launch(string file)
    {
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(file) { UseShellExecute = true }); }
        catch (Exception e) { AppModel.Shared.Flash(L("无法打开文件：%@", e.Message)); }
    }

    /// 我在群里发的文件：同 Chips，点了从电脑取回打开
    public static Control GroupChips(string groupId, IReadOnlyList<GroupMedia> files)
    {
        var stack = new StackPanel { Spacing = 6 };
        foreach (var file in files)
            stack.Children.Add(Chip(file.Name, file.Name).OnTap(() => OpenGroupFile(groupId, file)));
        return stack;
    }

    /// 我发过去的文件（消息里的 [附件] 行）：图标 + 文件名，点了打开
    public static Control Chips(string key, IReadOnlyList<string> paths)
    {
        var stack = new StackPanel { Spacing = 6 };
        foreach (var path in paths) stack.Children.Add(Chip(FileLinks.DisplayName(path), Format.ShortPath(path)).OnTap(() => Open(key, path)));
        return stack;
    }

    /// 一个文件：类型图标 + 文件名 + 类型
    static StackPanel Chip(string name, string tip)
    {
        var ext = FileLinks.Ext(name).ToUpperInvariant();
        var symbol = ext is "PNG" or "JPG" or "JPEG" or "GIF" or "HEIC" or "WEBP" ? "photo" : "doc.text";
        var glyph = Ui.Sym(symbol, 18, Bubble.TextColor(true));
        glyph.HorizontalAlignment = HorizontalAlignment.Center;
        glyph.VerticalAlignment = VerticalAlignment.Center;
        var icon = Ui.Box(glyph, new Avalonia.Thickness(0), "Fill10", 7);
        icon.Width = 34;
        icon.Height = 38;
        var kind = Ui.Text(ext.Length > 0 ? ext : L("文件"), 11, color: Bubble.TextColor(true));
        kind.Opacity = 0.7;
        var texts = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(Ui.Text(name, 13, color: Bubble.TextColor(true), lines: 2));
        texts.Children.Add(kind);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, MaxWidth = 260, Background = Avalonia.Media.Brushes.Transparent,
                                   Cursor = new Avalonia.Input.Cursor(Avalonia.Input.StandardCursorType.Hand) };
        row.Children.Add(icon);
        row.Children.Add(texts);
        ToolTip.SetTip(row, tip);
        return row;
    }
}
