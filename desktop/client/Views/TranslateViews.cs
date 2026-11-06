using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Kiteline.Model;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 消息下面那行小字里的「翻译」（同 Mac 版 TranslateBadge）：
/// 平时一个小「译」图标；鼠标移上去展开成「翻译 | 设置」（浮在上面，不挤动排版）；翻好后是「原文」+「设置」，点「原文」换回原来的语言
public sealed class TranslateBadge : Border
{
    readonly string id;
    readonly string text;

    public TranslateBadge(string id, string text)
    {
        this.id = id;
        this.text = text;
        TranslateUi.Ensure();
        Build();
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        Translator.Changed += OnChanged;
        Build();
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        Translator.Changed -= OnChanged;
        base.OnDetachedFromVisualTree(e);
    }

    void OnChanged(string? changed) { if (changed is null || changed == id) Build(); }

    void Build()
    {
        var state = Translator.StateOf(id);
        IsVisible = Translator.ShowBadge || state is not null;
        Child = state?.Phase switch
        {
            Translator.Phase.Working => Ui.H(2, new Spinner(10), Chip(L("翻译中…"), null, L("取消翻译"), () => Translator.Cancel(id))),
            Translator.Phase.Done => Ui.H(2, Translator.IsTranslated(id)
                    ? Chip(L("原文"), "arrow.uturn.backward", L("还原为原文"), () => Translator.Restore(id))
                    : Chip(L("译文"), "translate", L("显示译文（%@）", Translator.LanguageName(Translator.Target)), () => Translator.Tap(id, text)),
                Gear()),
            Translator.Phase.Failed => Ui.H(2, Chip(L("重试"), "exclamationmark.triangle", state.Error, () => Translator.Retranslate(id, text), "Removed"), Gear()),
            _ => Idle(),
        };
    }

    /// 没翻过：小图标；鼠标移上去在原地展开成「翻译 | 设置」（只画在上面，不改这一行的大小）
    Control Idle()
    {
        var icon = new Tap(Ui.Sym("translate", 11, "Text3"), () => Translator.Tap(id, text), 4).Tip(L("翻译"));
        var expanded = Ui.H(0, Chip(L("翻译"), "translate", Translator.Configured ? Translator.Summary : L("翻译这条消息"), () => Translator.Tap(id, text)),
            Ui.VRule("Separator", 0.5).Height(10), Gear());
        var pill = Ui.Box(expanded, new Thickness(2, 0), "ChatBackground", 9, "Separator", 0.5);
        pill.IsVisible = false;
        var panel = new FloatPanel { Children = { icon, pill } };
        panel.PointerEntered += (_, _) => pill.IsVisible = true;
        panel.PointerExited += (_, _) => pill.IsVisible = false;
        return panel;
    }

    Control Gear() => new Tap(Ui.Sym("gearshape", 11, "Text3"), () => TranslateUi.ShowSetup(L("重新翻译"), () => Translator.Retranslate(id, text)), 4).Tip(L("翻译设置"));

    static Control Chip(string title, string? symbol, string? tip, Action action, string color = "Text3") =>
        new Tap(Ui.H(3, symbol is null ? null : Ui.Sym(symbol, 11, color), Ui.Text(title, 11, color: color)).Pad(4, 1), action, 4).Tip(tip);

    /// 第一个孩子（图标）定大小；第二个（展开的那条）右边对齐图标、往左伸出去，盖在上面
    sealed class FloatPanel : Panel
    {
        protected override Size MeasureOverride(Size availableSize)
        {
            foreach (var child in Children) child.Measure(Size.Infinity);
            return Children.Count > 0 ? Children[0].DesiredSize : default;
        }

        protected override Size ArrangeOverride(Size finalSize)
        {
            if (Children.Count > 0) Children[0].Arrange(new Rect(finalSize));
            if (Children.Count > 1)
            {
                var size = Children[1].DesiredSize;
                Children[1].Arrange(new Rect(finalSize.Width - size.Width, (finalSize.Height - size.Height) / 2, size.Width, size.Height));
            }
            return finalSize;
        }
    }
}

/// 气泡里的文字：翻好了显示译文，切回原文显示原文（跟着 Translator.Changed 换）
public sealed class TranslatedContent : Border
{
    readonly string id;
    readonly Func<string, Control> make;
    readonly string original;
    /// 开了「自动翻译」时出现在屏幕上就自动翻（只给助手的回复）
    readonly bool auto;
    string? showing;

    public TranslatedContent(string id, string original, Func<string, Control> make, bool auto = false)
    {
        this.id = id;
        this.original = original;
        this.make = make;
        this.auto = auto;
        Child = make(original);
        showing = original;
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        Translator.Changed += OnChanged;
        OnChanged(id);
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        Translator.Changed -= OnChanged;
        base.OnDetachedFromVisualTree(e);
    }

    void OnChanged(string? changed)
    {
        if (changed is not null && changed != id) return;
        if (auto) Translator.AutoTranslate(id, original);
        var want = Translator.Shown(id) ?? original;
        if (want == showing) return;
        showing = want;
        Child = make(want);
    }
}

public static class TranslateUi
{
    /// 第一次点「翻译」弹设置（菜单里点的也走这里）
    public static void Ensure() => Translator.AskSetup ??= (id, text) => ShowSetup(L("翻译"), () => Translator.Retranslate(id, text));

    /// 右键菜单里的「翻译 / 显示原文」
    public static (string, Action)? MenuAction(string id, string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        Ensure();
        return Translator.IsTranslated(id) ? (L("显示原文"), () => Translator.Restore(id)) : (L("翻译"), () => Translator.Tap(id, text));
    }

    /// 翻译设置的小窗：原文语言、翻译为、翻译服务、消息下显示「翻译」；点主按钮记下设置并执行 confirm
    public static void ShowSetup(string confirmTitle, Action confirm)
    {
        Window? window = null;
        var content = new StackPanel { Children = { Section() } };
        var go = new GlassButton(confirmTitle, null, () =>
        {
            Translator.Configured = true;
            window?.Close();
            confirm();
        }, prominent: true, height: 30);
        window = Sheets.Show(L("翻译设置"), content, 480, 470, [go]);
    }

    /// 设置 → 通用 →「翻译」，弹窗里也是这一组
    public static Control Section()
    {
        var sources = new[] { Translator.Auto }.Concat(Translator.Languages).ToList();
        var targets = Translator.Languages.ToList();
        var source = Combo(sources.Select(l => l.Name), sources.FindIndex(l => l.Code == Translator.Source), i => { Translator.Source = sources[i].Code; Translator.Configured = true; });
        var target = Combo(targets.Select(l => l.Name), targets.FindIndex(l => l.Code == Translator.Target), i => { Translator.Target = targets[i].Code; Translator.Configured = true; });
        var footer = Ui.Text(Note(), 12, color: "Text2", lines: 0).Wrap().Margin(10, 8, 10, 0);
        var engines = Translator.Engines.ToList();
        var engine = Combo(engines.Select(e => L(e.Title)), engines.FindIndex(e => e.Id == Translator.Engine), i => { Translator.Engine = engines[i].Id; footer.Text = Note(); });
        var section = (StackPanel)Form.Section(L("翻译"), [
            Form.Row(L("原文语言"), source),
            Form.Row(L("翻译为"), target),
            Form.Row(L("翻译服务"), engine),
            Form.Toggle(L("自动翻译助手的回复"), Translator.AutoTranslateOn, on => Translator.AutoTranslateOn = on),
            Form.Toggle(L("在每条消息下显示「翻译」"), Translator.ShowBadge, on => Translator.ShowBadge = on),
        ]);
        section.Children.Add(footer);
        return section;
    }

    static string Note() => L("点消息下的「翻译」即可把这条消息翻译为所选语言，再点「原文」还原。") + L("开启自动翻译后，与目标语言不同的回复显示在屏幕上时自动翻译。") + Translator.EngineNote(Translator.Engine) + L("。翻译时消息文字会发送到该服务。");

    static ComboBox Combo(IEnumerable<string> items, int selected, Action<int> changed)
    {
        var box = new ComboBox { Width = 180, ItemsSource = items.ToList(), SelectedIndex = Math.Max(0, selected) };
        box.SelectionChanged += (_, _) => { if (box.SelectedIndex >= 0) changed(box.SelectedIndex); };
        return box;
    }
}
