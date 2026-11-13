# 插件清单

各 Agent 在各平台、各形态上 Kiteline 能做到什么。本文件由 `tools/oss/plugins_md.py` 按各插件声明的能力自动生成，每次同步代码时更新。

**全部** = 查看、回复、确认、回答提问、中断；**只读** = 只能查看会话和对话记录；✓ = 我们在该平台、该形态上实测通过；— = 该 Agent 没有这种形态。

为什么有的 Agent 只能查看，见[插件开发指南](guide/plugin-development.zh-CN.md#为什么有的-agent-只能查看)。想支持新的 Agent？欢迎按指南开发插件并提交 Pull Request。

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
| **Antigravity** <br><sub>[插件](plugins/antigravity)</sub> | 命令行 | 全部 <sup>5</sup> | 全部 ✓ <sup>6</sup> | 全部 ✓ <sup>5</sup> |
|  | 桌面版 | 只读 <sup>7</sup> | 只读 <sup>7</sup> | 只读 <sup>7</sup> |
| **CodeBuddy / WorkBuddy** <br><sub>[插件](plugins/codebuddy)</sub> | 命令行 | 全部 <sup>8</sup> | 只读 <sup>9</sup> | 全部 ✓ <sup>8</sup> |
|  | 桌面版 | 查看 · 回复 ✓ <sup>10</sup> | 只读 <sup>11</sup> | 只读 <sup>12</sup> |
| **Cursor** <br><sub>[插件](plugins/cursor)</sub> | 编辑器 | 查看 · 回复 · 确认 · 中断 <sup>13</sup> | 查看 · 回复 · 确认 · 中断 ✓ <sup>13</sup> | 查看 · 回复 · 确认 · 中断 ✓ <sup>13</sup> |
|  | 命令行 | 查看 · 回复 · 确认 · 中断 <sup>14</sup> | 只读 <sup>15</sup> | 查看 · 回复 · 确认 · 中断 ✓ <sup>14</sup> |
| **Grok Build** <br><sub>[插件](plugins/grok)</sub> | 命令行 | 全部 <sup>16</sup> | 只读 <sup>9</sup> | 全部 ✓ <sup>16</sup> |
| **Hermes** <br><sub>[插件](plugins/hermes)</sub> | 命令行 | 全部 <sup>17</sup> | 只读 <sup>9</sup> | 全部 ✓ <sup>17</sup> |
| **Kimi Code** <br><sub>[插件](plugins/kimi-code)</sub> | 命令行 | 全部 <sup>18</sup> | 只读 <sup>9</sup> | 全部 ✓ <sup>18</sup> |
|  | 桌面版 | 只读 <sup>19</sup> | — | — |
| **Muse Code** <br><sub>[插件](plugins/muse-code)</sub> | 命令行 | 查看 · 回复 · 中断 <sup>20</sup> | 只读 <sup>9</sup> | 查看 · 回复 · 中断 ✓ <sup>20</sup> |
| **pi** <br><sub>[插件](plugins/pi)</sub> | 命令行 | 查看 · 回复 · 中断 ✓ <sup>21</sup> | 查看 · 回复 · 中断 ✓ <sup>22</sup> | 查看 · 回复 · 中断 ✓ <sup>21</sup> |
| **Qwen Code** <br><sub>[插件](plugins/qwen-code)</sub> | 命令行 | 查看 · 回复 · 确认 · 中断 <sup>23</sup> | 只读 <sup>24</sup> | 查看 · 回复 · 确认 · 中断 ✓ <sup>23</sup> |
| **trae-agent** <br><sub>[插件](plugins/trae-agent)</sub> | 命令行 | 查看 · 回复 <sup>25</sup> | 只读 <sup>9</sup> | 查看 · 回复 ✓ <sup>25</sup> |
| **ZCode** <br><sub>[插件](plugins/zcode)</sub> | 桌面版 | 全部 ✓ <sup>26</sup> | 全部 ✓ <sup>26</sup> | 全部 ✓ <sup>26</sup> |
|  | 命令行 | 全部 ✓ <sup>26</sup> | 全部 ✓ <sup>26</sup> | 全部 ✓ <sup>26</sup> |

1. 命令行会话需要在 tmux 中运行
2. Codex 桌面版没有 Linux 版
3. DeepSeek Harness 桌面版没有 Linux 版
4. Proma 没有开放远程操作的接口，只能查看；回复和确认请在电脑上的 Proma 里操作
5. 回复和确认需要 Antigravity CLI 在 tmux 中运行，或在 Kiteline 新建任务时选它（后台运行）
6. 命令行在 Windows 终端里运行时可回复和确认（不用 tmux）
7. 桌面版和 IDE 的会话只能查看
8. 回复和确认需要 CodeBuddy Code 在 tmux 中运行，或在 Kiteline 新建任务时选它（后台运行）
9. 从手机操作暂未开放（Windows 上还没实测），只能查看
10. WorkBuddy 桌面版：查看任务和完整对话；从手机发消息、新建任务时 Kiteline 用它的深链接打开任务、粘贴并发送（会短暂切到 WorkBuddy）；确认操作请在 WorkBuddy 中进行
11. WorkBuddy 桌面版的任务只能查看（Windows 上从手机发消息还没实测）
12. WorkBuddy 桌面版的任务只能查看（Linux 版还没实测）
13. 需在 Cursor 的编辑器窗口中使用（Agents 窗口不支持），装好插件后重启一次 Cursor；对话空闲时从手机发消息需要 Kiteline 3.49.15 / 电脑端 1.0.20 以上
14. 回复和确认需要 Cursor 命令行在 tmux 中运行
15. Windows 上没有 tmux，只能查看；Cursor 正在工作时发的消息会在这一轮结束后自动发出
16. 回复和确认需要 Grok Build 在 tmux 中运行，或在 Kiteline 新建任务时选它（后台运行）
17. 回复和确认需要 Hermes 在 tmux 中运行，或在 Kiteline 新建任务时选它（后台运行）
18. 回复和确认需要 Kimi Code 在 tmux 中运行，或在 Kiteline 新建任务时选它（后台运行）
19. 桌面版的会话只能查看
20. 回复需要 Muse Code 在 tmux 中运行，或在 Kiteline 新建任务时选它（后台运行）；从手机确认命令暂未开放
21. 回复和中断需要 pi 在 tmux 中运行，或在 Kiteline 新建任务时选它（后台运行）
22. 在终端窗口中运行即可回复和中断
23. 回复和确认需要 Qwen Code 在 tmux 中运行，或在 Kiteline 新建任务时选它（后台运行）
24. Windows 上没有 tmux，只能查看
25. 发任务需要 trae-agent 在 tmux 中运行，或在 Kiteline 新建任务时选它（后台运行）
26. 使用 API Key 添加的模型时可从手机操作；账号登录的模型只能查看；电脑上发起的那一轮请在电脑上确认
