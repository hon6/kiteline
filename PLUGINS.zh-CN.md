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
| **ACP** <br><sub>[插件](plugins/acp)</sub> | 命令行 | 查看 · 回复 · 确认 · 中断 <sup>5</sup> | — <sup>6</sup> | 查看 · 回复 · 确认 · 中断 ✓ <sup>7</sup> |
| **Antigravity** <br><sub>[插件](plugins/antigravity)</sub> | 命令行 | 全部 <sup>8</sup> | 全部 ✓ <sup>9</sup> | 全部 ✓ <sup>8</sup> |
|  | 桌面版 | 只读 <sup>10</sup> | 只读 <sup>10</sup> | 只读 <sup>10</sup> |
| **CodeBuddy / WorkBuddy** <br><sub>[插件](plugins/codebuddy)</sub> | 命令行 | 全部 <sup>11</sup> | 只读 <sup>12</sup> | 全部 ✓ <sup>11</sup> |
|  | 桌面版 | 查看 · 回复 ✓ <sup>13</sup> | 只读 <sup>14</sup> | 只读 <sup>15</sup> |
| **Cursor** <br><sub>[插件](plugins/cursor)</sub> | 编辑器 | 查看 · 回复 · 确认 · 中断 <sup>16</sup> | 查看 · 回复 · 确认 · 中断 ✓ <sup>16</sup> | 查看 · 回复 · 确认 · 中断 ✓ <sup>16</sup> |
|  | 命令行 | 查看 · 回复 · 确认 · 中断 <sup>17</sup> | 只读 <sup>18</sup> | 查看 · 回复 · 确认 · 中断 ✓ <sup>17</sup> |
| **Grok Build** <br><sub>[插件](plugins/grok)</sub> | 命令行 | 全部 <sup>19</sup> | 只读 <sup>12</sup> | 全部 ✓ <sup>19</sup> |
| **Hermes** <br><sub>[插件](plugins/hermes)</sub> | 命令行 | 全部 <sup>20</sup> | 只读 <sup>12</sup> | 全部 ✓ <sup>20</sup> |
| **Kimi Code** <br><sub>[插件](plugins/kimi-code)</sub> | 命令行 | 全部 <sup>21</sup> | 只读 <sup>12</sup> | 全部 ✓ <sup>21</sup> |
|  | 桌面版 | 只读 <sup>22</sup> | — | — |
| **Muse Code** <br><sub>[插件](plugins/muse-code)</sub> | 命令行 | 查看 · 回复 · 中断 <sup>23</sup> | 只读 <sup>12</sup> | 查看 · 回复 · 中断 ✓ <sup>23</sup> |
| **oh-my-pi** <br><sub>[插件](plugins/oh-my-pi)</sub> | 命令行 | 查看 · 回复 · 回答 · 中断 ✓ <sup>24</sup> | 查看 · 回复 · 回答 · 中断 ✓ <sup>25</sup> | 查看 · 回复 · 回答 · 中断 ✓ <sup>24</sup> |
| **pi** <br><sub>[插件](plugins/pi)</sub> | 命令行 | 查看 · 回复 · 中断 ✓ <sup>26</sup> | 查看 · 回复 · 中断 ✓ <sup>27</sup> | 查看 · 回复 · 中断 ✓ <sup>26</sup> |
| **Qwen Code** <br><sub>[插件](plugins/qwen-code)</sub> | 命令行 | 查看 · 回复 · 确认 · 中断 <sup>28</sup> | 只读 <sup>29</sup> | 查看 · 回复 · 确认 · 中断 ✓ <sup>28</sup> |
| **trae-agent** <br><sub>[插件](plugins/trae-agent)</sub> | 命令行 | 查看 · 回复 <sup>30</sup> | 只读 <sup>12</sup> | 查看 · 回复 ✓ <sup>30</sup> |
| **ZCode** <br><sub>[插件](plugins/zcode)</sub> | 桌面版 | 全部 ✓ <sup>31</sup> | 全部 ✓ <sup>31</sup> | 全部 ✓ <sup>31</sup> |
|  | 命令行 | 全部 ✓ <sup>31</sup> | 全部 ✓ <sup>31</sup> | 全部 ✓ <sup>31</sup> |

1. 命令行会话需要在 tmux 中运行
2. Codex 桌面版没有 Linux 版
3. DeepSeek Harness 桌面版没有 Linux 版
4. Proma 没有开放远程操作的接口，只能查看；回复和确认请在电脑上的 Proma 里操作
5. 只接 Kiteline 新建的任务
6. Windows 上还没实测，暂不在新任务面板里列出
7. 只接 Kiteline 新建的任务（协议用 OpenCode 的 ACP 入口 + 假模型实测）
8. 回复和确认需要 Antigravity CLI 在 tmux 中运行，或在 Kiteline 新建任务时选它（后台运行）
9. 命令行在 Windows 终端里运行时可回复和确认（不用 tmux）
10. 桌面版和 IDE 的会话只能查看
11. 回复和确认需要 CodeBuddy Code 在 tmux 中运行，或在 Kiteline 新建任务时选它（后台运行）
12. 从手机操作暂未开放（Windows 上还没实测），只能查看
13. WorkBuddy 桌面版：查看任务和完整对话；从手机发消息、新建任务时 Kiteline 用它的深链接打开任务、粘贴并发送（会短暂切到 WorkBuddy）；确认操作请在 WorkBuddy 中进行
14. WorkBuddy 桌面版的任务只能查看（Windows 上从手机发消息还没实测）
15. WorkBuddy 桌面版的任务只能查看（Linux 版还没实测）
16. 需在 Cursor 的编辑器窗口中使用（Agents 窗口不支持），装好插件后重启一次 Cursor；对话空闲时从手机发消息需要 Kiteline 3.49.15 / 电脑端 1.0.20 以上
17. 回复和确认需要 Cursor 命令行在 tmux 中运行
18. Windows 上没有 tmux，只能查看；Cursor 正在工作时发的消息会在这一轮结束后自动发出
19. 回复和确认需要 Grok Build 在 tmux 中运行，或在 Kiteline 新建任务时选它（后台运行）
20. 回复和确认需要 Hermes 在 tmux 中运行，或在 Kiteline 新建任务时选它（后台运行）
21. 回复和确认需要 Kimi Code 在 tmux 中运行，或在 Kiteline 新建任务时选它（后台运行）
22. 桌面版的会话只能查看
23. 回复需要 Muse Code 在 tmux 中运行，或在 Kiteline 新建任务时选它（后台运行）；从手机确认命令暂未开放
24. 回复、回答和中断需要 omp 在 tmux 中运行，或在 Kiteline 新建任务时选它（后台运行）
25. 在终端窗口中运行即可回复、回答和中断
26. 回复和中断需要 pi 在 tmux 中运行，或在 Kiteline 新建任务时选它（后台运行）
27. 在终端窗口中运行即可回复和中断
28. 回复和确认需要 Qwen Code 在 tmux 中运行，或在 Kiteline 新建任务时选它（后台运行）
29. Windows 上没有 tmux，只能查看
30. 发任务需要 trae-agent 在 tmux 中运行，或在 Kiteline 新建任务时选它（后台运行）
31. 使用 API Key 添加的模型时可从手机操作；账号登录的模型只能查看；电脑上发起的那一轮请在电脑上确认
