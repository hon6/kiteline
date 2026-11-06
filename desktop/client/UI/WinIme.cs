using System.Runtime.InteropServices;
using System.Text;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Presenters;
using Avalonia.Input;
using Avalonia.VisualTree;

namespace Kiteline.UI;

/// Windows 上的中文输入法。Avalonia 11.3 自己那套有两个毛病（Win11 + 微软拼音，10-31 真机实测）：
/// 窗口里换过一次输入控件（消息框 ↔ 终端 ↔ 搜索框）后，新拿焦点的那个收不到组字和上屏的字，要重开客户端才好；候选窗固定在屏幕顶上。
/// 这里统一截窗口的输入法消息（IMM32）自己处理：拼音画在输入处、上屏的字插进去、候选窗放到光标下面。
/// 候选窗只用 CFS_CANDIDATEPOS 定位：CFS_EXCLUDE 会让搜狗等中文输入法卡住——候选照常弹出、选了字却不上屏
/// （11-05 反馈；Chromium、Avalonia 对中文输入法也只用 CANDIDATEPOS）
/// 只管终端（ITarget）和普通输入框（TextBox）；别的控件（代码编辑器）照旧交给 Avalonia
public static class WinIme
{
    /// 自己画组字、收上屏字的控件（终端）
    public interface ITarget
    {
        /// 输入光标那一格，在 Visual 里的坐标
        Rect CaretRect { get; }
        Visual Visual { get; }
        void Preedit(string text);
        void Commit(string text);
    }

    const uint WM_IME_STARTCOMPOSITION = 0x010D, WM_IME_ENDCOMPOSITION = 0x010E, WM_IME_COMPOSITION = 0x010F;
    const int GCS_COMPSTR = 0x0008, GCS_RESULTSTR = 0x0800, CFS_FORCE_POSITION = 0x0020, CFS_CANDIDATEPOS = 0x0040;

    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct CANDIDATEFORM { public int Index, Style; public POINT Pos; public RECT Area; }
    [StructLayout(LayoutKind.Sequential)] struct COMPOSITIONFORM { public int Style; public POINT Pos; public RECT Area; }

    [DllImport("imm32.dll")] static extern IntPtr ImmGetContext(IntPtr hwnd);
    [DllImport("imm32.dll")] static extern bool ImmReleaseContext(IntPtr hwnd, IntPtr himc);
    [DllImport("imm32.dll")] static extern int ImmGetCompositionStringW(IntPtr himc, int index, byte[]? buffer, int length);
    [DllImport("imm32.dll")] static extern bool ImmSetCandidateWindow(IntPtr himc, ref CANDIDATEFORM form);
    [DllImport("imm32.dll")] static extern bool ImmSetCompositionWindow(IntPtr himc, ref COMPOSITIONFORM form);

    static readonly HashSet<TopLevel> installed = [];

    /// 每个窗口（主窗口、弹窗、看大图……）出来时挂上（App 启动时登记了 Loaded 的类处理）
    public static void Install(TopLevel top)
    {
        if (!OperatingSystem.IsWindows() || !installed.Add(top)) return;
        Win32Properties.AddWndProcHookCallback(top, (IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam, ref bool handled) => Hook(top, hwnd, msg, lParam, ref handled));
        top.Closed += (_, _) => installed.Remove(top);
    }

    static IntPtr Hook(TopLevel top, IntPtr hwnd, uint msg, IntPtr lParam, ref bool handled)
    {
        if (msg is not (WM_IME_STARTCOMPOSITION or WM_IME_COMPOSITION or WM_IME_ENDCOMPOSITION)) return IntPtr.Zero;
        var target = top.FocusManager?.GetFocusedElement() switch
        {
            ITarget own => own,
            TextBox box when !box.IsReadOnly => new BoxTarget(box),
            _ => null,
        };
        if (target is null) return IntPtr.Zero;
        var himc = ImmGetContext(hwnd);
        if (himc == IntPtr.Zero) return IntPtr.Zero;
        // 上屏的字读不到时交回系统默认处理（转成 WM_IME_CHAR → WM_CHAR，Avalonia 当打字收下），别把这次上屏吞掉
        var passOn = false;
        try
        {
            if (msg == WM_IME_COMPOSITION)
            {
                var flags = (long)lParam;
                if ((flags & GCS_RESULTSTR) != 0)
                {
                    var result = Read(himc, GCS_RESULTSTR);
                    if (result.Length > 0) target.Commit(result);
                    else passOn = true;
                }
                if ((flags & GCS_COMPSTR) != 0) target.Preedit(Read(himc, GCS_COMPSTR));
            }
            else if (msg == WM_IME_ENDCOMPOSITION) target.Preedit("");
            Place(top, target, himc);
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"[输入法] {e.Message}");
        }
        finally { ImmReleaseContext(hwnd, himc); }
        // 处理了：不再交给 Avalonia 和系统默认处理（不会再生成 WM_CHAR，字不会进两遍）
        handled = !passOn;
        return IntPtr.Zero;
    }

    static string Read(IntPtr himc, int index)
    {
        var length = ImmGetCompositionStringW(himc, index, null, 0);
        if (length <= 0) return "";
        var buffer = new byte[length];
        ImmGetCompositionStringW(himc, index, buffer, length);
        return Encoding.Unicode.GetString(buffer);
    }

    /// 组字框、候选窗放到输入光标那儿（窗口客户区里的物理像素）
    static void Place(TopLevel top, ITarget target, IntPtr himc)
    {
        var rect = target.CaretRect;
        if (target.Visual.TranslatePoint(rect.TopLeft, top) is not Point at) return;
        var scale = top.RenderScaling;
        int x = (int)(at.X * scale), y = (int)(at.Y * scale), h = Math.Max(1, (int)(rect.Height * scale));
        var composition = new COMPOSITIONFORM { Style = CFS_FORCE_POSITION, Pos = new POINT { X = x, Y = y } };
        ImmSetCompositionWindow(himc, ref composition);
        var candidate = new CANDIDATEFORM
        {
            Index = 0, Style = CFS_CANDIDATEPOS, Pos = new POINT { X = x, Y = y + h },
        };
        ImmSetCandidateWindow(himc, ref candidate);
    }

    /// 普通输入框：拼音交给它的 TextPresenter 画（同 Avalonia 自己显示的样子），上屏的字当作打字插进去
    sealed class BoxTarget(TextBox box) : ITarget
    {
        TextPresenter? Presenter => box.GetVisualDescendants().OfType<TextPresenter>().FirstOrDefault();

        public Visual Visual => (Visual?)Presenter ?? box;

        public Rect CaretRect
        {
            get
            {
                if (Presenter is not TextPresenter presenter) return new Rect(0, 0, 1, box.Bounds.Height);
                var at = presenter.TextLayout.HitTestTextPosition(Math.Clamp(box.CaretIndex, 0, (box.Text ?? "").Length));
                return new Rect(at.X, at.Y, Math.Max(1, at.Width), Math.Max(1, at.Height));
            }
        }

        public void Preedit(string text) => Presenter?.SetValue(TextPresenter.PreeditTextProperty, string.IsNullOrEmpty(text) ? null : text);

        public void Commit(string text)
        {
            Preedit("");
            if (string.IsNullOrEmpty(text)) return;
            var before = box.Text ?? "";
            box.RaiseEvent(new TextInputEventArgs { RoutedEvent = InputElement.TextInputEvent, Text = text });
            // 没插进去（事件被别处拦了等）：直接替换选中的文字，保证选了的字一定进框；有长度上限的框不硬塞
            if ((box.Text ?? "") != before || box.MaxLength > 0) return;
            int start = Math.Clamp(Math.Min(box.SelectionStart, box.SelectionEnd), 0, before.Length);
            int end = Math.Clamp(Math.Max(box.SelectionStart, box.SelectionEnd), start, before.Length);
            box.Text = before[..start] + text + before[end..];
            box.SelectionStart = box.SelectionEnd = box.CaretIndex = start + text.Length;
        }
    }
}
