<div align="center">

<img src="assets/images/icon.png" width="112" alt="Kiteline">

# Kiteline

### 电脑上已经在跑的编程 Agent，用手机来遥控。

Kiteline 把你各台电脑上的 Claude Code、Codex、OpenCode、DeepSeek Harness 会话（VS Code 里、终端里、Remote-SSH 远端的都算）放到 iPhone、iPad 和 Apple Watch 上。Agent 照你现在的用法用，人离开电脑时，在手机上看每一步、批准请求、回答提问、派下一件活。

<br>

[![官网](https://img.shields.io/badge/官网-tars.betac.cn-D97757?style=for-the-badge)](https://tars.betac.cn)
[![下载](https://img.shields.io/badge/下载-macOS%20%7C%20Windows%20%7C%20Linux-2B2B2B?style=for-the-badge)](https://tars.betac.cn/download/)
[![App Store](https://img.shields.io/badge/App%20Store-iPhone%20%7C%20iPad%20%7C%20Watch-2B2B2B?style=for-the-badge&logo=apple&logoColor=white)](https://apps.apple.com/app/id6825244029)

[![License](https://img.shields.io/badge/license-AGPL--3.0-3B6FB6?style=flat-square)](LICENSE)
[![Release](https://img.shields.io/github/v/release/hon6/kiteline?style=flat-square&color=D97757)](https://github.com/hon6/kiteline/releases)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?style=flat-square&logo=swift&logoColor=white)
![Python](https://img.shields.io/badge/Python-3.10%2B-3776AB?style=flat-square&logo=python&logoColor=white)
![.NET](https://img.shields.io/badge/.NET%2010-Avalonia-512BD4?style=flat-square&logo=dotnet&logoColor=white)

[English](README.md) · **简体中文**

</div>

<br>

![Kiteline：手机上说一句，Agent 写代码、跑测试、截图发回来](assets/images/hero-zh.jpg)

## 安装

**电脑上**（Mac、Windows、Linux），一行命令：

```bash
# macOS、Linux
curl -fsSL https://tars.betac.cn/install.sh | sh
```

```powershell
# Windows（PowerShell）
irm https://tars.betac.cn/install.ps1 | iex
```

也可以用包管理器：Mac 上 `brew install --cask hon6/kiteline/kiteline`；Windows 上先 `scoop bucket add kiteline https://github.com/hon6/scoop-kiteline`，再 `scoop install kiteline`。

没有图形界面的 Linux 服务器，加 `--service` 装成 systemd 用户服务：`curl -fsSL https://tars.betac.cn/install.sh | sh -s -- --service`。想用普通安装包，到[官网](https://tars.betac.cn)或 [GitHub Releases](https://github.com/hon6/kiteline/releases) 下载。脚本会按官网公布的 SHA-256 校验每个下载。

**手机上**，到 [App Store](https://apps.apple.com/app/id6825244029) 下载 Kiteline（iPhone、iPad、Apple Watch），扫电脑上显示的配对码。不用注册账号。

**安卓手机，或不想装 App**，用微信扫下面的码打开 Kiteline 小程序，演示模式可直接体验；配对电脑的方法相同。

<img src="assets/images/miniprogram-qr.jpg" width="160" alt="Kiteline 微信小程序码">

电脑上已有的 Agent 会话会马上出现在手机上。详见[安装说明](guide/user/install.zh-CN.md)。

## 「要花钱吗？」

- 电脑端开源（AGPL-3.0），免费，不限功能。
- 手机和电脑连同一个 Wi-Fi 时，手机 App 全部功能免费。
- 只有远程访问（在别的网络连回自己的电脑）需要订阅 Kiteline Pro，大约每月一杯奶茶的价格，用来付中继服务器的钱。
- 不用注册账号，不要 API Key，不改 Agent 的配置。

## 为什么用 Kiteline

- **不用换工具**：会话照样在 VS Code、终端或 Remote-SSH 里，手机接管的就是同一个会话，不用搬到另一个界面里重新开。
- **不碰你的 AI 账号**：不登录 Claude 或任何 AI 服务，不读 API Key 和登录凭证，不调用任何模型接口；只读 Agent 自己写下的会话记录，只通过 Agent 自己提供的接口操作。
- **Agent 自己汇报**：自带技能让 Agent 发截图、用 Playwright 在真实浏览器里把网页功能走一遍并把报告发给你、把只有你能做的事记成待办、报告做到第几步。
- **抬腕就能批**：命令、计划、提问推到锁屏和 Apple Watch；锁屏和灵动岛上实时显示谁在等你、做到第几步；高风险命令一律二次确认。
- **整个团队一屏看全**：世界模式和数据流大屏把每台电脑上的每个会话放在一块屏上。

## 演示

<table>
<tr>
<td width="50%"><a href="https://tars.betac.cn/assets/video/intro-zh.mp4#t=64"><img src="assets/media/demo-zh-1.webp" alt="语音派活"></a><br><sub><b>语音派活</b>：手机上说一句，电脑上的 Agent 立刻开工。</sub></td>
<td width="50%"><a href="https://tars.betac.cn/assets/video/intro-zh.mp4#t=150"><img src="assets/media/demo-zh-2.webp" alt="随时确认"></a><br><sub><b>随时确认</b>：允许、拒绝、回答提问、批准计划，轻点即可。</sub></td>
</tr>
<tr>
<td width="50%"><a href="https://tars.betac.cn/assets/video/intro-zh.mp4#t=120"><img src="assets/media/demo-zh-3.webp" alt="多 Agent"></a><br><sub><b>多 Agent</b>：插件市场装一个就行，不用等 App 更新。</sub></td>
<td width="50%"><a href="https://tars.betac.cn/assets/video/intro-zh.mp4#t=206"><img src="assets/media/demo-zh-4.webp" alt="世界模式"></a><br><sub><b>世界模式</b>：每台电脑一间机房，每个会话一个工位。</sub></td>
</tr>
</table>

<sub>点击任意片段观看完整介绍视频。</sub>

## 核心能力

| | |
|---|---|
| **所有 Agent 一个列表** | Claude Code（VS Code 与终端）、Codex、OpenCode、DeepSeek Harness、Qwen Code、Kimi Code、CodeBuddy、ZCode、Antigravity、Grok Build 等；新的 Agent 以签名插件下发，无需等待 App 更新。 |
| **随时随地确认** | 权限请求、计划审批、选择题都以卡片形式出现在锁屏、手机和手表上。 |
| **多种回复方式** | 打字、按住说话（本机离线识别）、附照片或截图，也能在任一项目中新建任务。 |
| **看到工作本身** | 实时步骤、命令、代码改动、测试输出与图片；内置带 Git 的代码编辑器，以及跑在会话里的终端。 |
| **任务进度** | 每个会话显示当前阶段（如「2/4 开发中」），Agent 可直接把截图和报告发到手机。 |
| **目标** | 在手机上给 Claude Code 或 Codex 会话设一个目标（`/goal`），Agent 一轮轮做下去，达成才停。会话列表显示第几轮，对话页显示最近一次检查说还差什么，达成、做不到或中途停下时推送提醒。 |
| **待办** | Agent 需要*你*亲自处理的事项从对话中自动识别并持续跟踪，直到完成。 |
| **会话群** | 不同电脑、不同项目的会话经 Kiteline 互相协作。 |
| **世界模式** | 像素风办公室，每个会话是工位上的一个小人，整个团队一眼看全。 |
| **数据流大屏** | 所有会话一块屏：每个会话读了什么、做了什么、产出去了哪。每次工具调用是一根线，调用发生时一串光点沿线流过。 |
| **锁屏实时活动** | Agent 工作或等你确认时，iPhone 锁屏和灵动岛实时显示每个会话的状态：等你确认的排在最前，工作中的标出第几步，全部做完显示「全部完成」。轻点直接进入会话；由电脑经推送更新，App 不用开着。 |
| **网页回复** | 需要用图表、对比表、流程图说明的结论，Agent 做成网页发到对话里；手机上在 App 内打开，可缩放、可交互、可转发，网页读取不到 App 的任何数据。 |
| **链接协作** | 提示词链接：把任务要求做成链接，同事点开即打开填好提示词、选好项目的新任务，确认后才执行。只读分享：生成局域网网址，同一 Wi-Fi 下用浏览器看会话的对话和步骤，页面由你的电脑直接提供。 |

## 支持的 Agent

| Agent | 在手机上能做什么 |
|---|---|
| **Claude Code** | 完整操作：VS Code 扩展与命令行 |
| **Codex** | 完整操作：命令行、VS Code 扩展、桌面版 |
| **OpenCode** | 完整操作 |
| **Cursor** | 插件即将上线（源码在 [`plugins/cursor`](plugins/cursor)） |
| **Qwen Code** | 在 tmux 中运行时可回复、确认；其他情况只读 |
| **DeepSeek Harness** | 完整操作（需手动开启） |
| **Proma** | 只读 |
| **Kimi Code** · **Hermes** · **Grok Build** | 命令行在 tmux 中运行时可回复、确认、回答提问、中断、关闭；其他情况只读 |
| **CodeBuddy Code** · **WorkBuddy** | CodeBuddy Code 在 tmux 中可完整操作；WorkBuddy 桌面版只读 |
| **ZCode** | 从手机发消息，这一轮要确认的命令、要回答的提问出现在手机上，也可以中断 |
| **Antigravity** | 命令行在 tmux 中可回复、确认、回答、中断、关闭；桌面版和 IDE 只读 |
| **Muse Code** | 在 tmux 中可回复、中断、关闭（命令在电脑上确认） |
| **trae-agent** | 查看任务和完整记录；在 tmux 中运行时可从手机派任务 |

各平台、各形态的详细情况见 **[插件清单](PLUGINS.zh-CN.md)**，它按各插件声明的能力自动生成，随每次发版更新。

**为什么有的 Agent 只能查看？** Kiteline 不碰你的 AI 凭证，也不修改任何 Agent，只通过 Agent 自己提供的途径操作：它的本机服务或 IPC 接口、hooks 或编辑器 URI 这类扩展点，或者它所在的终端（tmux）。一个 Agent 如果这些都没有提供，Kiteline 仍能从磁盘读取并显示它的会话和完整对话，但不会为了操作它而模拟输入或改动 Agent 本身。App 会说明某个会话为什么只读、怎样才能操作（例如把命令行放进 tmux 里运行）。详见[插件开发指南](guide/plugin-development.zh-CN.md#为什么有的-agent-只能查看)。

**开发插件**：新的 Agent 以插件形式接入，一个插件由一份清单加一个在会话监听里运行的 Python 小模块组成。[插件开发指南](guide/plugin-development.zh-CN.md)介绍了清单、接口和必须遵守的规则，用 `tools/plugin_check.py` 可以在本机测试插件。欢迎提交 Pull Request：我们审核、实测后签名，发布到官方插件索引，所有 Kiteline 用户无需更新 App 即可使用。

## 常见问题

**会不会导致 Claude、Codex 账号被封？**
Kiteline 不登录任何 AI 服务，不用你订阅的 token，也不调用任何模型接口，不会改变 Agent 和服务商之间的通信方式。Agent 照旧在你的电脑上、用你自己的账号运行；Kiteline 读它们写下的会话记录，再像你自己打字一样往同一个会话里输入。

**代码会经过你们的服务器吗？**
同一个网络里不会：手机直连电脑，走 HTTPS，配对时锁定电脑自己签发的证书。在别的网络时先尝试点对点直连，打不通才经中继转发；全程端到端加密，中继看不到内容，也不存储。详见[远程访问](guide/user/remote-access.zh-CN.md)。

**要改变工作习惯吗？**
不用。会话照样在 VS Code 或终端里开，Kiteline 自己找到它们。终端里的会话要能从手机回复，需要跑在 tmux 里。

**有安卓版吗？**
安卓手机用微信扫[安装](#安装)一节里的小程序码，打开 Kiteline 小程序即可。原生 App 支持 iPhone、iPad 和 Apple Watch。

**服务器上的 Agent 能用吗？**
能。在服务器上用 `--service` 装 Kiteline；或者在电脑端把服务器加成 Remote-SSH 远端，Kiteline 通过 SSH 部署一个只读的监听脚本（只需要 Python 3.8+ 标准库）。

**和 Claude Code 官方的 Remote Control 有什么不同？**
Remote Control 是在 Claude App 里接着用一个 Claude Code 会话。Kiteline 把每台电脑上的每个 Agent 放进一个列表，还有锁屏和 Apple Watch 上的确认、Agent 发回的截图和测试报告、待办、目标、会话群、带 Git 的代码编辑器和终端。

更多见[常见问题](guide/user/faq.zh-CN.md)。

## 文档

- [安装与首次使用](guide/user/install.zh-CN.md)
- [支持的 Agent 和各自的接入方式](guide/user/agents.zh-CN.md)
- [确认请求、计划审批和提问](guide/user/approvals.zh-CN.md)
- [远程访问](guide/user/remote-access.zh-CN.md)
- [隐私与安全](guide/user/privacy.zh-CN.md)
- [常见问题](guide/user/faq.zh-CN.md)
- 给别的 Agent 写插件：[插件开发指南](guide/plugin-development.md)

## 架构

```mermaid
flowchart LR
    subgraph Devices["iPhone · iPad · Apple Watch"]
        APP["Kiteline App"]
    end
    subgraph Computer["你的电脑 · macOS / Windows / Linux"]
        HOST["Kiteline 电脑端<br/>Swift · Python"]
        WL["会话监听<br/>kiteline-watch.py"]
        UI["VS Code · 终端 · tmux"]
    end
    subgraph Servers["Remote-SSH 服务器"]
        WR["经 SSH 运行的会话监听"]
    end
    AG[("Claude Code · Codex · OpenCode<br/>Qwen Code · Kimi Code · CodeBuddy · ZCode · …")]
    PUSH["推送网关 → APNs"]

    APP <-- "HTTPS + SSE · 局域网 · 本机根证书" --> HOST
    APP <-. "点对点 QUIC · 中继兜底" .-> HOST
    HOST -- "JSON Lines · stdio" --> WL
    HOST -- "JSON Lines · SSH" --> WR
    WL --> AG
    WR --> AG
    HOST -- "辅助功能 · 编辑器 URI · PTY" --> UI
    HOST -. "Web Push · RFC 8291 密文" .-> PUSH -.-> APP
```

## 技术实现

- **会话发现**：会话监听是一个单文件 Python 脚本（`watcher/kiteline-watch.py`），**不依赖任何第三方库**，在本机和任意 Remote-SSH 主机上经普通 SSH 运行。它跟踪 Claude Code 的会话注册表与 JSONL 对话记录，通过 Codex、OpenCode 各自的本机服务协议与其通信，其他 Agent 由插件接入（比如借助 Agent 提供的 hooks），最终统一成一条 JSON Lines 事件流。
- **输入投递**：Claude Code 没有可写的 stdin，Kiteline 从前端送入：
  - **VS Code 里的会话**：用辅助功能 API 找到对应窗口，调用扩展自带的 `vscode://anthropic.claude-code/open` URI 切换会话并预填内容，核对输入框后提交。
  - **tmux 里的命令行会话**：由会话监听直接投递。
  - **其他终端会话**：沿进程树找到所在的终端 App 再送入。
  - **Codex、OpenCode**：回复、确认、回答提问都走它们的原生协议。
- **传输与配对**：手机与电脑在局域网内走 HTTPS。每台电脑生成自己的根证书，并用 X.509 名称约束限定在私有地址段内。实时状态以 Server-Sent Events 推送，电脑经 Bonjour / mDNS 自动发现。配对使用 6 位验证码，或扫描带一次性令牌和根证书指纹的二维码。
- **端到端加密推送**：通知内容在电脑上按 Web Push（RFC 8291 `aes128gcm`、RFC 8292 VAPID）加密，只在设备上由通知服务扩展解密；推送网关转给 APNs 的始终是密文。
- **远程访问**（闭源组件）：基于 Rust 与 [iroh](https://github.com/n0-computer/iroh)。连接以设备公钥寻址，走 QUIC，能打洞直连就直连、打不通走中继兜底；在 Wi-Fi 与蜂窝网络之间切换时连接不中断。只允许已配对的设备连入。
- **签名插件**：内置之外的 Agent 通过 Ed25519 签名的插件索引下发。插件清单声明能力（查看、回复、确认、回答、中断……）与所需权限，各端按 Agent 实际支持的能力渲染界面。
- **本机语音识别**：按住说话由 [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) 与 Fun-ASR-Nano 模型在本机完成，音频不离开你自己的设备。
- **实时活动**：iPhone 把 ActivityKit 的推送启动令牌和每个实时活动的更新令牌报给电脑，电脑按「一轮工作」开始、合并更新（新的待确认立即发，其余最多每 8 秒一次）、空闲 90 秒后结束，经推送网关发给 APNs 的 `liveactivity` 通道。按 Apple 的规定这部分内容是明文，只放会话标题和状态。
- **只读分享**：有分享时电脑另开一个只认 `/g/` 的局域网 HTTP 端口（没有分享就关），页面每 8 秒带 ETag 轮询一次快照；快照现取会话记录生成，不含思考过程、图片和关键信息，内容不经过任何服务器。
- **世界模式**：[three.js](https://threejs.org) 场景各端共用一份，由同一条状态流驱动。
- **数据流大屏**：同样是 three.js，和世界模式共用宿主协议。卡片是贴 Canvas 纹理的薄板；每种线是一个环形写入的 `LineSegments`，线的数量有上限。底层的线用普通叠加，几百根叠起来也只是一层淡灰；只有亮起的线（最多 320 根）和光点（一个着色器驱动的 `Points`，最多 1500 颗）用加法混合。自动运镜正对平面，平移、放大到最忙的卡片，列出刚经过它的几次调用。

## 技术栈

| 组件 | 技术 | 规模 |
|---|---|---|
| Mac 电脑端 | Swift、SwiftUI、AppKit；终端用 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | 约 2.6 万行 |
| 共用界面（Mac 与 iPhone） | SwiftUI 模块 `KitelineKit` | 约 4.2 万行 |
| 会话监听 | Python 3，仅标准库 | 约 1.3 万行 |
| Windows、Linux 电脑端 | Python 3.10+、cryptography、zeroconf、sherpa-onnx | 约 1.7 万行 |
| Windows、Linux 窗口 | C#、.NET 10、[Avalonia](https://avaloniaui.net) | 约 3.4 万行 |
| 代码编辑器 | [CodeMirror 6](https://codemirror.net) | |
| 世界模式、数据流大屏 | [three.js](https://threejs.org) | |
| 远程访问（*不在本仓库*） | Rust、iroh（QUIC） | |

## 截图

<table>
<tr>
<td><img src="assets/images/iphone/01-agents.jpg" alt="所有 Agent"></td>
<td><img src="assets/images/iphone/03-approve.jpg" alt="确认请求"></td>
<td><img src="assets/images/iphone/06-plan.jpg" alt="批准计划"></td>
<td><img src="assets/images/iphone/07-live.jpg" alt="实时同步"></td>
<td><img src="assets/images/iphone/02-world.jpg" alt="世界模式"></td>
</tr>
<tr>
<td><img src="assets/images/iphone/04-codex.jpg" alt="Codex"></td>
<td><img src="assets/images/iphone/05-voice.jpg" alt="语音"></td>
<td><img src="assets/images/iphone/08-overview.jpg" alt="全局概览"></td>
<td><img src="assets/images/iphone/09-watch.jpg" alt="Apple Watch"></td>
<td><img src="assets/images/iphone/10-remote.jpg" alt="远程访问"></td>
</tr>
</table>

<table>
<tr>
<td width="25%"><img src="assets/images/watch/1-now.jpg" alt="手表：确认"></td>
<td width="25%"><img src="assets/images/watch/3-question.jpg" alt="手表：回答"></td>
<td width="25%"><img src="assets/images/watch/4-plan.jpg" alt="手表：计划"></td>
<td width="25%"><img src="assets/images/watch/5-usage.jpg" alt="手表：用量"></td>
</tr>
</table>

![Mac 端：两个会话并排，一个计划等批准，两个会话在互发消息](assets/images/mac-main.jpg)

![Mac 端的世界模式](assets/images/mac-world.jpg)

![数据流大屏：所有会话一块屏，每次工具调用一根线，调用发生时光点沿线流过](assets/images/flow-board.jpg)

<table>
<tr>
<td width="62%"><img src="assets/images/ipad-split.jpg" alt="iPad 分栏"></td>
<td width="38%"><img src="assets/images/mac-g-pick-panel.jpg" alt="拉群协作"></td>
</tr>
</table>

## 关于开源与订阅

**自行构建**：全部源码均在本仓库公开。如果您有时间、乐于动手，欢迎在遵守 AGPL-3.0 许可证的前提下自行构建、修改和二次开发，也欢迎通过 Issue 提出建议。

**直接使用**：如果您不希望在构建和维护上投入时间与 token，请直接从[官网](https://tars.betac.cn/download/)下载正式版：

- 手机与电脑连接同一 Wi-Fi 时，全部功能免费使用；
- 如需在任何网络环境下使用，可在 iPhone App 中订阅 Kiteline Pro。订阅费用约为每月一杯奶茶的价格，用于服务器续费与日常维护。

## 目录结构

```text
.
├── Sources/                Mac 电脑端（Swift、SwiftUI）
├── Resources/              Mac 资源、世界模式（three.js）、代码编辑器（CodeMirror）
├── KitelineKit/            Mac 与 iPhone 共用的 SwiftUI 组件
├── watcher/
│   └── kiteline-watch.py   会话监听，本机或经 SSH 运行（仅标准库）
├── desktop/
│   ├── kiteline/           Windows、Linux 电脑端（Python）
│   ├── client/             Windows、Linux 原生窗口（C#、Avalonia）
│   └── packaging/          PyInstaller 与 tar.gz 打包
├── plugins/                单独下发的 Agent 插件
├── PLUGINS.zh-CN.md        各 Agent 在各平台的支持情况（自动生成）
├── tools/plugin_check.py   在本机测试插件
├── tests/                  HTTP 接口与会话监听的集成测试
├── build.sh · install.sh   Mac 构建与安装
└── docs/                   插件开发指南、Agent 对接说明、世界模式
```

不在本仓库的部分：远程访问组件、iPhone / iPad / Apple Watch App 外壳（配对、设置、小组件、Xcode 工程），以及服务器（中继、推送网关、统计）。用本仓库编出的版本可在局域网内使用；远程访问请使用正式版，见[关于开源与订阅](#关于开源与订阅)。

## 从源码构建

### Mac

需要：

- macOS 14 或更新。
- Xcode，或者只装命令行工具（`xcode-select --install`）。
- Python 3（会话监听用）。

```bash
git clone https://github.com/hon6/kiteline.git
cd kiteline
./install.sh                 # 构建，装到 /Applications/Kiteline.app 并启动
./install.sh my-server       # 同时监听这些 Remote-SSH 主机（需免密 ssh）
./build.sh                   # 只构建 → dist/Kiteline.app
```

从源码编的版本会替换已装的正式版 Kiteline，数据和配对都保留。为此，少数运行时标识沿用项目早期的名字：

- 数据目录 `~/Library/Application Support/TARS`；
- 可执行文件名；
- 装到各台电脑上的 `~/.ccpulse/ccpulse-watch.py`。

第一次构建时会生成一个本机自签的签名身份，之后重编，系统权限都会保留。

本机离线语音识别（可选）：从 `sherpa-onnx-core` 1.13.8 的 macOS arm64 wheel 里取出 `libsherpa-onnx-c-api.dylib` 和 `libonnxruntime.dylib`，放进 `vendor/sherpa-onnx/lib/`。没有这两个文件时，会改用系统语音识别。

### Windows、Linux

需要 Python 3.10 或更新。

```bash
cd desktop
python3 -m venv .venv && . .venv/bin/activate      # Windows：.venv\Scripts\activate
pip install -r requirements.txt
python -m kiteline               # 在浏览器里打开控制台，挂托盘图标
python -m kiteline --headless    # 没有图形界面的服务器：配对码打印在终端里
```

打包：

- Linux 安装包：`bash desktop/packaging/build-linux.sh`。
- Windows 安装包：`desktop\packaging\build-windows.ps1`。
- 原生窗口（.NET 10）：先运行 `bash desktop/client/publish.sh linux-x64 win-x64`，再带 `KITELINE_WITH_CLIENT=1` 打包。

### 配对手机

1. 从 [App Store](https://apps.apple.com/app/id6825244029) 安装 Kiteline。
2. 在电脑上打开「手机访问」：Mac 在菜单栏图标里，Windows、Linux 在托盘或控制台里。
3. 用手机扫码，不需要注册账号。

## 隐私与安全

- **不碰 AI 凭证**：Kiteline 不登录 Claude 或任何 AI 服务，不读取、不转发 API Key 和会话令牌，不调用模型接口，也不修改 Agent 本身。
- **只在你自己的设备之间**：对话和代码只在你的电脑和手机之间加密传输。
- **使用统计**：电脑每 15 分钟向 Kiteline 服务器报一次精简数据，内容是设备类型和版本、用了哪些 Agent 和模型、token 数，以及你设置的显示名称；各种编号都做了哈希。不含对话、代码、文件名、路径和会话标题。可在设置里关闭「发送使用统计」（见 `Sources/UsageStats.swift`、`desktop/kiteline/stats.py`）。
- **朗读**：如果选用微软语音朗读回复（可选，经 edge-tts），要朗读的文字会发到微软服务器合成。

## 参与贡献

欢迎提 Issue、参与讨论、提交 Pull Request，尤其欢迎**为新的 Agent 开发插件**（见[插件开发指南](guide/plugin-development.zh-CN.md)）。提 Pull Request 前请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可

Copyright © 2026 hon6。以 [GNU Affero 通用公共许可证 v3.0](LICENSE)（AGPL-3.0）发布：分发修改后的版本，或者把修改后的版本作为网络服务提供给他人使用，都必须按同样的许可公开源代码。需要其他授权方式，请联系 hon6@foxmail.com。

「Kiteline」名称和纸鸢标志代表官方 App，修改后的版本请勿使用。各 Agent 的名称和标志（取自 [LobeHub Icons](https://github.com/lobehub/lobe-icons)，MIT）归各自所有者，只用来标明会话来自哪个工具。Kiteline 与 Anthropic、OpenAI、Anysphere 及其他 Agent 厂商没有隶属或背书关系。第三方许可见 `Resources/ThirdPartyNotices.json`。

<div align="center"><br><a href="https://tars.betac.cn"><b>tars.betac.cn</b></a></div>
