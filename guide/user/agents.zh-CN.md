# 支持的 Agent

[English](agents.md)

Kiteline 不改任何 Agent 的配置，也不碰它的登录，只通过 Agent 本来就提供的途径跟随它：它写在磁盘上的会话记录、它自己的本地服务或进程间接口、hook 或编辑器链接这类扩展点，或者它运行的终端。

| Agent | 在哪里用 | 手机上能做什么 |
|---|---|---|
| **Claude Code** | VS Code 扩展（本机和 Remote-SSH 窗口）、终端，或由 Kiteline 在后台运行 | 全部：看进度、回复、确认、回答提问、切换权限模式、模型和思考强度、压缩上下文、设目标 |
| **Codex** | 终端、VS Code 扩展、ChatGPT 桌面版 | 全部，走 Codex 自己的接口，不用设置；Codex 不必在前台 |
| **OpenCode** | 终端 | 全部，经 Kiteline 自动安装的插件接入（重启一次 OpenCode） |
| **DeepSeek Harness** | 桌面版、命令行 | 全部，需在「设置 → 插件」里打开一次 |
| **Cursor** | 编辑器、命令行 | 查看、回复、确认、中断 |
| **ZCode** | 桌面版、命令行 | 全部 |
| **Kimi Code** · **Hermes** · **Grok Build** · **CodeBuddy Code** · **Antigravity 命令行** | 终端 | 全部：新建任务时直接选用，由 Kiteline 在后台运行（Mac、Linux），或自己在 tmux 里启动 |
| **Qwen Code** | 终端 | 查看、回复、确认、中断（后台运行或 tmux） |
| **Muse Code** · **pi** | 终端 | 查看、回复、中断（后台运行或 tmux） |
| **trae-agent** | 终端 | 查看任务和完整记录，可从手机派任务 |
| **WorkBuddy** | 桌面版 | Mac 上可查看、回复；其他平台只能查看 |
| **Proma** · **Antigravity 桌面版** | 桌面版 | 只能查看 |

各平台完整的支持情况见 [PLUGINS.md](../../PLUGINS.md)。

## 各 Agent 说明

- **VS Code 里的 Claude Code**：Kiteline 在 Claude Code 自己的插件目录里放一个带 Kiteline 标记的小插件，由它在会话里接收你的消息、确认和回答，不切换窗口，电脑锁屏时也能送达。这个插件加载之前就开着的会话，Kiteline 仍像你一样往同一个会话的输入框里输入：提交前先核对当前标签是不是目标会话，对不上就报错停下，不会发错会话。
- **后台运行的 Claude Code**：在 Mac、Linux 电脑上新建任务、恢复会话时，Kiteline 默认直接在后台运行 Claude Code，不打开 VS Code；需要看代码时，点会话标签栏上的「在 VS Code 中打开」。经 SSH 连接的远端电脑，在「设置 → 来源」里逐台检测出口后开启。
- **终端里的 Claude Code**：自己在终端里启动的会话要能从手机回复，需要跑在 tmux 里，例如 `tmux new -A -s claude claude`。不在 tmux 里的会话照样能看。
- **其他命令行 Agent**：Kimi Code、Grok Build、Hermes、Muse Code、Antigravity 命令行、CodeBuddy Code、Qwen Code、pi、trae-agent 可在 Mac、Linux 上新建任务时直接选用，由 Kiteline 在后台运行，不用自己开 tmux。
- **DeepSeek Harness**：它没有给第三方工具的接口，Kiteline 只能读它本地的连接密钥（不是模型 API Key），所以默认关闭，等你看过接入方式后自己打开。
- **目标（`/goal`）**：Claude Code 2.1.139 及以上、终端里的 Codex。Codex 的目标还能暂停、继续。Codex 桌面版和 VS Code 扩展里的会话可以看目标进展，设定目标需在 Codex 里进行。

## 为什么有的 Agent 只能查看

Agent 没有提供让别的程序代你回复的途径时，Kiteline 照样显示它的会话和完整记录，但不会模拟输入，也不会修改 Agent 来接管它。App 里会写明某个会话为什么只能查看、怎样能开启更多操作，比如在新建任务时直接选用它，或把命令行放进 tmux 里跑。

## 接入更多 Agent

内置之外的 Agent 以签名插件的形式发布：一个清单加一个运行在监听脚本里的小 Python 模块，新插件不用更新 App 就能送到所有用户。见[插件开发指南](../plugin-development.zh-CN.md)。
