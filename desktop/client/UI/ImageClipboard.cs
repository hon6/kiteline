using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;

namespace Kiteline.UI;

/// 把一张图放进剪贴板（看大图的「拷贝」，同 Mac 版写 NSPasteboard）。
/// Windows：写 CF_DIB（画图、微信、Office、浏览器都认），另带一份 PNG 格式保留透明；Avalonia 只会写自定义格式，系统格式自己写。
/// Linux：交给 Avalonia 写 image/png（X11 / XWayland 的剪贴板目标就是 MIME 类型）
/// 粘贴截图（PasteImages）也在这里
public static class ImageClipboard
{
    /// 文本框粘贴（Ctrl+V、Shift+Insert、右键「粘贴」）时剪贴板里是图就交给 attach，不是图照常粘贴文字（同 Mac 版 MacComposer 的 paste）。
    /// 拦下文本框自己的粘贴、await 读一次剪贴板再决定。别在界面线程上 GetResult() 同步等剪贴板：Windows 剪贴板正被别的程序占着时
    /// Avalonia 隔 100 毫秒重试、续上要回界面线程，X11 要等界面线程收选区事件，同步等就互相等死（11-02 在输入框 Ctrl+V 整个卡死）。
    /// 文字也用这次读到的，不再交回文本框自己的 Paste()：剪贴板一直被占着时它重试完抛的不是超时异常，没人接住整个程序会退出
    public static void PasteImages(this TextBox box, int max, Action<IReadOnlyList<byte[]>> attach)
    {
        box.PastingFromClipboard += async (_, e) =>
        {
            e.Handled = true;
            var (images, text) = await Read(TopLevel.GetTopLevel(box), max);
            if (images.Count > 0) attach(images);
            else if (!string.IsNullOrEmpty(text)) box.SelectedText = text;   // 同文本框自己的粘贴：替换选中的字，光标落在贴进去的字后面
        };
    }

    /// 读剪贴板：从资源管理器 / 文件管理器拷贝的图片文件（最多 max 张），或截图（截图键、截图工具、微信 / QQ 截图、浏览器「复制图片」）放进 Images；
    /// 同时带了一段文字的（如 Excel 单元格，会附带一张位图）照常按文字粘贴，只是网址的还是当图。读不了（一直被别的程序占着）两样都空，这次粘贴不做
    public static async Task<(List<byte[]> Images, string? Text)> Read(TopLevel? top, int max)
    {
        var images = new List<byte[]>();
        if (top?.Clipboard is not { } clipboard) return (images, null);
        try
        {
            using var data = await clipboard.TryGetDataAsync();
            if (data is null) return (images, null);
            var text = data.Contains(DataFormat.Text) ? await data.TryGetValueAsync(DataFormat.Text) : null;
            if (data.Contains(DataFormat.File) && await data.TryGetValuesAsync(DataFormat.File) is { } files)
            {
                foreach (var path in files.Select(f => f.TryGetLocalPath()).Where(IsImage).Take(max))
                    images.Add(await File.ReadAllBytesAsync(path!));
                if (images.Count > 0) return (images, null);
            }
            if (data.Contains(DataFormat.Bitmap) && (text?.Trim() is not { Length: > 0 } words || words.StartsWith("http"))
                && await data.TryGetValueAsync(DataFormat.Bitmap) is { } bitmap)
            {
                using (bitmap)
                using (var stream = new MemoryStream())
                {
                    bitmap.Save(stream);
                    images.Add(stream.ToArray());
                }
            }
            return (images, text);
        }
        catch (Exception) { return ([], null); }
    }

    static bool IsImage(string? path) => path is not null && new[] { ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".heic" }.Contains(Path.GetExtension(path).ToLowerInvariant());

    public static async Task<bool> Copy(TopLevel? top, byte[] data)
    {
        if (top is null) return false;
        try
        {
            using var bitmap = new Bitmap(new MemoryStream(data));
            if (OperatingSystem.IsWindows())
                return top.TryGetPlatformHandle()?.Handle is IntPtr hwnd && hwnd != IntPtr.Zero && Win32(hwnd, bitmap, Png(bitmap, data));
            if (top.Clipboard is not { } clipboard) return false;
            var item = new DataObject();
            item.Set("image/png", Png(bitmap, data));
            await clipboard.SetDataObjectAsync(item);
            return true;
        }
        catch (Exception) { return false; }
    }

    /// PNG 原样用，JPEG 转成 PNG
    static byte[] Png(Bitmap bitmap, byte[] data)
    {
        if (data.Length > 3 && data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47) return data;
        using var stream = new MemoryStream();
        bitmap.Save(stream);
        return stream.ToArray();
    }

    // MARK: Windows

    const uint CF_DIB = 8, GMEM_MOVEABLE = 0x0002;

    static bool Win32(IntPtr hwnd, Bitmap bitmap, byte[] png)
    {
        var dib = Dib(bitmap);
        // 打开剪贴板要带窗口：不带的话清空后剪贴板没有主人，SetClipboardData 会失败
        var opened = false;
        for (var i = 0; i < 10 && !(opened = OpenClipboard(hwnd)); i++) Thread.Sleep(30);
        if (!opened) return false;
        try
        {
            EmptyClipboard();
            var ok = Put(CF_DIB, dib);
            Put(RegisterClipboardFormatW("PNG"), png);
            return ok;
        }
        finally { CloseClipboard(); }
    }

    static bool Put(uint format, byte[] bytes)
    {
        var memory = GlobalAlloc(GMEM_MOVEABLE, (UIntPtr)bytes.Length);
        if (memory == IntPtr.Zero) return false;
        var pointer = GlobalLock(memory);
        Marshal.Copy(bytes, 0, pointer, bytes.Length);
        GlobalUnlock(memory);
        if (SetClipboardData(format, memory) != IntPtr.Zero) return true;
        GlobalFree(memory);   // 交给剪贴板后归系统管；没交出去的自己放掉
        return false;
    }

    /// 32 位、自下而上的 DIB（BITMAPINFOHEADER + 像素）。透明的地方垫白底：多数程序不认 DIB 里的透明度，不垫会变成黑底
    static byte[] Dib(Bitmap bitmap)
    {
        int w = bitmap.PixelSize.Width, h = bitmap.PixelSize.Height, stride = w * 4;
        var pixels = new byte[stride * h];
        // 先画到渲染位图上再取像素（BGRA、预乘）：解码出来的格式随图片、平台不同
        using (var canvas = new RenderTargetBitmap(bitmap.PixelSize))
        {
            using (var context = canvas.CreateDrawingContext())
                context.DrawImage(bitmap, new Rect(0, 0, w, h));
            var pin = GCHandle.Alloc(pixels, GCHandleType.Pinned);
            try { canvas.CopyPixels(new PixelRect(0, 0, w, h), pin.AddrOfPinnedObject(), pixels.Length, stride); }
            finally { pin.Free(); }
        }
        var dib = new byte[40 + pixels.Length];
        void Int(int offset, int value) => BitConverter.TryWriteBytes(dib.AsSpan(offset, 4), value);
        Int(0, 40); Int(4, w); Int(8, h);
        BitConverter.TryWriteBytes(dib.AsSpan(12, 2), (short)1);    // 平面数
        BitConverter.TryWriteBytes(dib.AsSpan(14, 2), (short)32);   // 每像素位数
        Int(20, pixels.Length);
        for (var y = 0; y < h; y++)
        {
            var from = y * stride;
            var to = 40 + (h - 1 - y) * stride;
            for (var x = 0; x < stride; x += 4)
            {
                var a = pixels[from + x + 3];
                // 预乘过的颜色叠到白底上：c + (255 - a)
                dib[to + x] = (byte)Math.Min(255, pixels[from + x] + 255 - a);
                dib[to + x + 1] = (byte)Math.Min(255, pixels[from + x + 1] + 255 - a);
                dib[to + x + 2] = (byte)Math.Min(255, pixels[from + x + 2] + 255 - a);
                dib[to + x + 3] = 255;
            }
        }
        return dib;
    }

    [DllImport("user32.dll", SetLastError = true)] static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32.dll")] static extern bool CloseClipboard();
    [DllImport("user32.dll")] static extern bool EmptyClipboard();
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetClipboardData(uint format, IntPtr memory);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterClipboardFormatW(string name);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr memory);
    [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr memory);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalFree(IntPtr memory);
}
