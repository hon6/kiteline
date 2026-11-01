using Avalonia.Controls;
using Kiteline.UI;
using static Kiteline.Lang;

namespace Kiteline.Views;

/// 左边栏入口格子对应的页面（今日动态、历史会话、用量、项目、待办、收藏）
public static class Pages
{
    static Control Placeholder(string symbol, string title) => Empty.State(symbol, title, L("正在移植"));
    public static Control Today() => new TodayPage();
    public static Control History() => new HistoryPage();
    public static Control Usage() => new UsagePage();
    public static Control Projects() => new ProjectsPage();
    public static Control Todos() => new TodosPage();
    public static Control Favorites() => new FavoritesPage();
}
