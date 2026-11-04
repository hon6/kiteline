# 插件清单

各 Agent 在各平台、各形态上 Kiteline 能做到什么。本文件由 `tools/oss/plugins_md.py` 按各插件声明的能力自动生成，每次同步代码时更新。

**全部** = 查看、回复、确认、回答提问、中断；**只读** = 只能查看会话和对话记录；✓ = 我们在该平台、该形态上实测通过；— = 该 Agent 没有这种形态。

为什么有的 Agent 只能查看，见[插件开发指南](docs/plugin-development.zh-CN.md#为什么有的-agent-只能查看)。想支持新的 Agent？欢迎按指南开发插件并提交 Pull Request。

[English](PLUGINS.md) · **简体中文**

| Agent | 形态 | macOS | Windows | Linux |
|---|---|---|---|---|
| **Claude Code** <br><sub>原生支持</sub> | VS Code 扩展 | 全部 ✓ | 全部 ✓ | 全部 ✓ |
|  | 命令行 | 全部 ✓ | 全部 | 全部 ✓ <sup>1</sup> |
| **Codex** <br><sub>内置插件</sub> | 命令行 | 全部 ✓ | 全部 ✓ | 全部 ✓ |
|  | VS Code 扩展 | 全部 ✓ | 全部 ✓ | 全部 ✓ |
|  | 桌面版 | 全部 ✓ | 全部 ✓ | — <sup>2</sup> |
| **OpenCode** <br><sub>内置插件</sub> | 命令行 | 全部 ✓ | 全部 ✓ | 全部 ✓ |
| **DeepSeek Harness** <br><sub>内置插件，需手动开启</sub> | 桌面版 | 全部 ✓ | 全部 ✓ | — <sup>3</sup> |
|  | 命令行 | 全部 | 全部 | 全部 ✓ |
| **Proma** <br><sub>内置插件</sub> | 桌面版 | 只读 <sup>4</sup> | 只读 <sup>4</sup> | 只读 ✓ <sup>4</sup> |
| **Cursor** <br><sub>[插件](plugins/cursor)</sub> | 编辑器 | 查看 · 回复 · 确认 · 中断 <sup>5</sup> | 查看 · 回复 · 确认 · 中断 ✓ <sup>5</sup> | 查看 · 回复 · 确认 · 中断 ✓ <sup>5</sup> |
|  | 命令行 | 查看 · 回复 · 确认 · 中断 <sup>6</sup> | 只读 <sup>7</sup> | 查看 · 回复 · 确认 · 中断 ✓ <sup>6</sup> |
| **Grok Build** <br><sub>[插件](plugins/grok)，即将上线</sub> | 命令行 | 全部 <sup>8</sup> | 只读 <sup>9</sup> | 全部 ✓ <sup>8</sup> |
| **Hermes** <br><sub>[插件](plugins/hermes)，即将上线</sub> | 命令行 | 全部 <sup>10</sup> | 只读 <sup>9</sup> | 全部 ✓ <sup>10</sup> |
| **Kimi Code** <br><sub>[插件](plugins/kimi-code)，即将上线</sub> | 命令行 | 全部 <sup>11</sup> | 只读 <sup>9</sup> | 全部 ✓ <sup>11</sup> |
|  | 桌面版 | 只读 <sup>12</sup> | — | — |
| **Qwen Code** <br><sub>[插件](plugins/qwen-code)</sub> | 命令行 | 查看 · 回复 · 确认 · 中断 <sup>13</sup> | 只读 <sup>9</sup> | 查看 · 回复 · 确认 · 中断 ✓ <sup>13</sup> |

1. 命令行会话需要在 tmux 中运行
2. Codex 桌面版没有 Linux 版
3. DeepSeek Harness 桌面版没有 Linux 版
4. Proma 没有开放远程操作的接口，只能查看；回复和确认请在电脑上的 Proma 里操作
5. 需在 Cursor 的编辑器窗口中使用（Agents 窗口不支持），装好插件后重启一次 Cursor；对话空闲时从手机发消息需要 Kiteline 3.49.15 / 电脑端 1.0.20 以上
6. 回复和确认需要 Cursor 命令行在 tmux 中运行
7. Windows 上没有 tmux，只能查看；Cursor 正在工作时发的消息会在这一轮结束后自动发出
8. 回复和确认需要 Grok Build 在 tmux 中运行
9. Windows 上没有 tmux，只能查看
10. 回复和确认需要 Hermes 在 tmux 中运行
11. 回复和确认需要 Kimi Code 在 tmux 中运行
12. 桌面版的会话只能查看
13. 回复和确认需要 Qwen Code 在 tmux 中运行
