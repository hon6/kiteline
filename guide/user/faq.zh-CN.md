# 常见问题

[English](faq.md)

### 会不会导致 Claude、Codex 账号被封？

Kiteline 不登录任何 AI 服务，不用你订阅的 token，也不调用任何模型接口，不会改变 Agent 和服务商之间的通信方式。Agent 照旧在你的电脑上、用你自己的账号运行。

### 需要 API Key 吗？

不需要，Agent 照旧用它自己的登录。

### 收费吗？

电脑端免费、开源。手机和电脑连同一个 Wi-Fi 时，手机上全部功能免费；只有在别的网络远程连回电脑才需要 Kiteline Pro。见[远程访问](remote-access.zh-CN.md)。

### 代码会经过你们的服务器吗？

同一个网络里不会。在别的网络时先尝试点对点直连，打不通才用中继；全程端到端加密，中继看不到内容。

### 要改变工作习惯吗？

不用。会话照样在 VS Code 或终端里开；终端里的会话要能从手机回复，需要跑在 tmux 里。

### 电脑要一直开着吗？

要。Agent 在你的电脑上运行，所以电脑要开着、联着网；请关闭自动睡眠。

### 有安卓版或网页版吗？

目前还没有，手机端只有 iPhone、iPad 和 Apple Watch。

### 一台电脑能连几台手机？

可以连多台，每台单独配对，也能单独移除。

### 一台手机能看几台电脑？

可以看多台，所有已配对电脑上的会话都在一个列表里，可按项目、Agent 或电脑分组。

### 服务器上的 Agent 能用吗？

能。在服务器上用 `--service` 安装 Kiteline（见[安装](install.zh-CN.md)），或者用 VS Code Remote-SSH 打开项目，Kiteline 通过 SSH 跟随远端。

### 和 Claude Code 官方的 Remote Control 有什么不同？

Remote Control 是在 Claude App 里接着用一个 Claude Code 会话。Kiteline 把每台电脑上的每个 Agent 放进一个列表，还有锁屏和 Apple Watch 上的确认、Agent 发回的截图和测试报告、待办、目标、会话群、带 Git 的代码编辑器和终端。

### 开源吗？

Mac、Windows、Linux 电脑端、会话监听脚本和 Agent 插件在[本仓库](https://github.com/hon6/kiteline)以 AGPL-3.0 开源。远程访问组件、iPhone / iPad / Apple Watch 的 App 外壳和服务器不开源。
