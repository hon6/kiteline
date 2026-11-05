# 支持的 Agent

[English](agents.md)

Kiteline 不改任何 Agent 的配置，也不碰它的登录，只通过 Agent 本来就提供的途径跟随它：它写在磁盘上的会话记录、它自己的本地服务或进程间接口、hook 或编辑器链接这类扩展点，或者它运行的终端。

| Agent | 在哪里用 | 手机上能做什么 |
|---|---|---|
| **Claude Code** | VS Code 扩展（本机和 Remote-SSH 窗口）、终端 | 全部：看进度、回复、确认、回答提问、切换权限模式、模型和思考强度、压缩上下文、设目标 |
| **Codex** | 终端、VS Code 扩展、ChatGPT 桌面版 | 全部，走 Codex 自己的接口，不用设置；Codex 不必在前台 |
| **OpenCode** | 终端 | 全部，经 Kiteline 自动安装的插件接入（重启一次 OpenCode） |
| **DeepSeek Harness** | 桌面版、命令行 | 全部，需在「设置 → 插件」里打开一次 |
| **Qwen Code** | 终端 | 跑在 tmux 里时可回复、确认；否则只能查看 |
| **Proma** | 桌面版 | 只能查看 |

各平台完整的支持情况见 [PLUGINS.md](../../PLUGINS.md)。

## 各 Agent 说明

- **VS Code 里的 Claude Code**：Kiteline 像你一样往同一个会话的输入框里输入。提交前先核对当前标签是不是目标会话，对不上就报错停下，不会发错会话。
- **终端里的 Claude Code**：要能从手机回复，需要跑在 tmux 里，例如 `tmux new -A -s claude claude`。不在 tmux 里的会话照样能看。
- **DeepSeek Harness**：它没有给第三方工具的接口，Kiteline 只能读它本地的连接密钥（不是模型 API Key），所以默认关闭，等你看过接入方式后自己打开。
- **目标（`/goal`）**：Claude Code 2.1.139 及以上、终端里的 Codex。Codex 的目标还能暂停、继续。Codex 桌面版和 VS Code 扩展里的会话可以看目标进展，设定目标需在 Codex 里进行。

## 为什么有的 Agent 只能查看

Agent 没有提供让别的程序代你回复的途径时，Kiteline 照样显示它的会话和完整记录，但不会模拟输入，也不会修改 Agent 来接管它。App 里会写明某个会话为什么只能查看、怎样能开启更多操作，比如把命令行放进 tmux 里跑。

## 接入更多 Agent

内置之外的 Agent 以签名插件的形式发布：一个清单加一个运行在监听脚本里的小 Python 模块，新插件不用更新 App 就能送到所有用户。见[插件开发指南](../plugin-development.zh-CN.md)。
