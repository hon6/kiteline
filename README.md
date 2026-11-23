<div align="center">

<img src="assets/images/icon.png" width="112" alt="Kiteline">

# Kiteline

### A remote for the coding agents already running on your computers.

Kiteline puts every Claude Code, Codex, OpenCode and DeepSeek Harness session on your computers (in VS Code, the terminal, over Remote-SSH, or run by Kiteline in the background) on your iPhone, iPad and Apple Watch — and on Android through a WeChat Mini Program. Keep using your agents exactly as you do now. When you step away, follow every step, approve requests, answer questions and send the next task from your phone.

<br>

[![Website](https://img.shields.io/badge/Website-tars.betac.cn-D97757?style=for-the-badge&logoColor=white)](https://tars.betac.cn)
[![Download](https://img.shields.io/badge/Download-macOS%20%7C%20Windows%20%7C%20Linux-2B2B2B?style=for-the-badge)](https://tars.betac.cn/download/)
[![App Store](https://img.shields.io/badge/App%20Store-iPhone%20%7C%20iPad%20%7C%20Watch-2B2B2B?style=for-the-badge&logo=apple&logoColor=white)](https://apps.apple.com/app/id6825244029)

[![License](https://img.shields.io/badge/license-AGPL--3.0-3B6FB6?style=flat-square)](LICENSE)
[![Release](https://img.shields.io/github/v/release/hon6/kiteline?style=flat-square&color=D97757)](https://github.com/hon6/kiteline/releases)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?style=flat-square&logo=swift&logoColor=white)
![Python](https://img.shields.io/badge/Python-3.10%2B-3776AB?style=flat-square&logo=python&logoColor=white)
![.NET](https://img.shields.io/badge/.NET%2010-Avalonia-512BD4?style=flat-square&logo=dotnet&logoColor=white)

**English** · [简体中文](README.zh-CN.md)

</div>

<br>

![Kiteline: speak a task on your phone, the agent codes, tests and sends back a screenshot](assets/images/hero-en.jpg)

## Install

**On your computer** (Mac, Windows or Linux), one command:

```bash
# macOS and Linux
curl -fsSL https://tars.betac.cn/install.sh | sh
```

```powershell
# Windows (PowerShell)
irm https://tars.betac.cn/install.ps1 | iex
```

Or with a package manager: `brew install --cask hon6/kiteline/kiteline` on the Mac, or `scoop bucket add kiteline https://github.com/hon6/scoop-kiteline` then `scoop install kiteline` on Windows.

On a Linux server without a desktop, add `--service` to run it as a systemd user service: `curl -fsSL https://tars.betac.cn/install.sh | sh -s -- --service`. Prefer a regular installer? Download it from [tars.betac.cn](https://tars.betac.cn/en/) or [GitHub Releases](https://github.com/hon6/kiteline/releases). The script verifies each download against its published SHA-256 checksum.

**On your phone**, get Kiteline from the [App Store](https://apps.apple.com/app/id6825244029) (iPhone, iPad and Apple Watch) and scan the pairing code shown on your computer. No account to create.

**On Android, or without installing an app**, scan this code with WeChat to open the Kiteline Mini Program. Demo mode lets you try it right away; pair it with your computer the same way.

<img src="assets/images/miniprogram-qr.jpg" width="160" alt="Kiteline WeChat Mini Program code">

Your existing agent sessions show up on the phone right away. More in the [install guide](guide/user/install.md).

## "So what's the catch?"

- The desktop app is open source (AGPL-3.0) and free, with no limits.
- The phone app is free, every feature included, whenever your phone is on the same Wi-Fi as your computer.
- Only remote access, reaching your computer from another network, needs Kiteline Pro: about the price of a cup of bubble tea a month, which pays for the relay servers.
- No account, no API keys, and no changes to your agents' configuration.

## Why Kiteline

- **Nothing new to move into.** Your sessions stay in VS Code, the terminal or Remote-SSH, exactly where they are. The phone picks up the very same session; there is no second interface to start your work in. Or let Kiteline run Claude Code in the background: no VS Code window, and replies and approvals still go through when the computer is locked.
- **Never touches your AI login.** Kiteline doesn't sign in to Claude or any other AI service, never reads API keys or tokens and never calls a model API. It reads the transcripts your agents already write and acts only through interfaces they offer.
- **Agents report back.** Built-in skills let agents send screenshots, walk through web features in a real browser with Playwright and send you the report, track what only you can do as to-dos, and show which stage they are at.
- **Approve from your wrist.** Commands, plans and questions reach the lock screen and Apple Watch; a Live Activity shows who is waiting and what step each session is on; risky commands always ask twice.
- **See the whole team at once.** World mode and the Flow Board show every session on every computer on one screen.

## See it in action

<table>
<tr>
<td width="50%"><a href="https://tars.betac.cn/assets/video/kiteline-1-en.mp4"><img src="assets/media/demo-en-1.webp" alt="Dispatch by voice, get a screenshot back"></a><br><sub><b>No more coding blind.</b> Send a task by voice; the agent reports back with screenshots.</sub></td>
<td width="50%"><a href="https://tars.betac.cn/assets/video/kiteline-2-en.mp4"><img src="assets/media/demo-en-2.webp" alt="Approve from the lock screen or your watch"></a><br><sub><b>Approve from anywhere.</b> Lock screen, phone or watch; risky commands always ask twice.</sub></td>
</tr>
<tr>
<td width="50%"><a href="https://tars.betac.cn/assets/video/kiteline-3-en.mp4"><img src="assets/media/demo-en-3.webp" alt="Every computer, every agent"></a><br><sub><b>Every computer, every agent.</b> Mac, Windows, Linux and Remote-SSH in one list.</sub></td>
<td width="50%"><a href="https://tars.betac.cn/assets/video/kiteline-4-en.mp4"><img src="assets/media/demo-en-4.webp" alt="Start work on the go"></a><br><sub><b>Start work on the go.</b> Dispatch a task and check today's progress at a glance.</sub></td>
</tr>
</table>

<sub>Click any clip to watch the full video.</sub>

## Highlights

| | |
|---|---|
| **One list for every agent** | Claude Code (VS Code, terminal and background), Codex, OpenCode, DeepSeek Harness, Cursor, Qwen Code, Kimi Code, CodeBuddy, ZCode, Antigravity, Grok Build, Hermes, Muse Code, pi, trae-agent and more. New agents ship as signed plugins, so supporting one doesn't need an app update. |
| **Approve anywhere** | Permission requests, plan approvals and multiple-choice questions become cards on the lock screen, the phone and the watch. |
| **Reply your way** | Type, hold to talk (on-device speech recognition), attach photos and screenshots, or start a new task in any project. |
| **See the work, not just the chat** | Live steps, commands, diffs, test output and images, plus a code editor with Git and a terminal that runs inside each session. When an agent needs a terminal, its command runs in that session's terminal too, labelled with the device. |
| **Background sessions** | On a Mac or Linux computer, new tasks and resumed sessions run Claude Code in the background by default, with no VS Code window. Messages and approvals never take the foreground and still work with the computer locked; move a session into VS Code with one click. Remote hosts over SSH can be turned on device by device. |
| **Session groups and execution trace** | On the computer, put related sessions into a group: group tabs sit along the top of the window and switching to a group lays its sessions out in columns. On Mac and iPad, the execution trace shows agents, turns and every step on a timeline, jumps to the first error and replays the run. |
| **Agent browser** | Agents use the browser Kiteline provides. A live preview appears in the session; enlarge it to follow every step, take over for sign-ins and CAPTCHAs, then hand back. Every run is recorded for replay. |
| **Message queue and restart** | Messages sent while the agent is busy line up above the input box: reorder, edit, delete or jump the queue. Restart one session or many; the conversation is kept. |
| **Several computers** | Connect your phone to several computers running Kiteline and see their sessions in one list; computers can add each other too, and every device can have an alias. |
| **Widgets and stats** | Home Screen and Lock Screen widgets show recent sessions, plan limits and today's tokens. Turn a day, a week or a single task into a shareable image of tokens, lines changed and time online — numbers only. |
| **Task progress** | Each session shows its current stage (for example "2/4 Developing"), and agents can send screenshots and reports straight to your phone. |
| **Goals** | Give a Claude Code or Codex session a goal (`/goal`) from your phone and the agent keeps working, round after round, until it is met. The session list shows which round it is on, the chat shows what the last check said is still missing, and you get a notification when the goal is met, can't be met or stops. |
| **To-dos** | Anything the agent needs *you* to do is picked up from the conversation and tracked until it's done. |
| **Group chats** | Sessions on different computers and projects coordinate with each other through Kiteline. |
| **New layout and AR mode** | On the computer, switch to a layout like VS Code: an icon bar, project tabs, files and Git beside the conversation, a status bar. AR mode turns sessions into floating windows in space: the most active sit nearest, a window shakes when it has news, and you can reply or talk to it right there. |
| **Send from other apps** | Pick Kiteline in WeChat's "Open with other app", Finder's Share or a browser's share menu to hand a file, image, text or link to a session, or start a new one. |
| **World mode** | A voxel office where every session is a worker at a desk, so you can see the whole team at a glance. |
| **Flow Board** | Every session on one screen: what each one reads, what it does and where the output goes. Each tool call is a line, and a trail of light runs along it the moment the call happens. |
| **Live Activities** | While agents work or wait for you, the iPhone Lock Screen and Dynamic Island show every session’s status: waiting ones first, running ones with their current step, and All done when everything stops. Tap to jump into the session; your computer updates it through push, so the app does not need to be open. |
| **Web replies** | When a result is best shown as a chart, comparison table or flow diagram, the agent sends it as a web page; on the phone it opens in the app — zoom, interact, share — and cannot read any app data. |
| **Links** | Prompt links turn a task into a link: your teammate opens a New Task with the prompt and project filled in, and nothing runs until they confirm. Read-only sharing creates a local network address so anyone on the same Wi-Fi can follow the conversation and steps in a browser, served straight from your computer. |

## Supported agents

| Agent | What you can do from your phone |
|---|---|
| **Claude Code** | Full control: VS Code extension, CLI, or run by Kiteline in the background (no VS Code window needed) |
| **Codex** | Full control: CLI, VS Code extension, desktop app |
| **OpenCode** | Full control |
| **DeepSeek Harness** | Full control (opt-in) |
| **Cursor** | Editor and CLI: view, reply, approve, interrupt |
| **ZCode** | Full control in the desktop app and the CLI |
| **Kimi Code** · **Hermes** · **Grok Build** · **CodeBuddy Code** · **Antigravity CLI** | Full control: pick one when starting a task and Kiteline runs it in the background (Mac and Linux), or start it in tmux yourself |
| **Qwen Code** | View, reply, approve, interrupt (same: background or tmux) |
| **Muse Code** · **pi** | View, reply, interrupt (same: background or tmux) |
| **trae-agent** | View tasks and full records; send tasks from your phone |
| **WorkBuddy** | Desktop app on the Mac: view and reply. View only elsewhere |
| **Proma** · **Antigravity desktop app** | View only |

The per-platform matrix is in **[PLUGINS.md](PLUGINS.md)**. It is generated from the capabilities each plugin declares and updated with every release.

**Why are some agents view-only?** Kiteline never touches your AI credentials and never modifies an agent. It only acts through interfaces the agent itself offers: its local server or IPC, extension points such as hooks or an editor URI, or the terminal (tmux) it runs in. When an agent offers none of these, Kiteline can still show its sessions and full transcripts from disk, but it won't simulate input or patch the agent to take control. The app tells you why a session is view-only and how to enable more, for example by picking the agent when you start a task, or by starting the CLI in tmux. Details are in the [plugin guide](guide/plugin-development.md#why-some-agents-are-view-only).

**Build a plugin.** New agents are added as plugins: a manifest plus a small Python module running in the watcher. The [plugin development guide](guide/plugin-development.md) covers the manifest, the interface and the rules, and `tools/plugin_check.py` lets you test a plugin on your own machine. Open a pull request: we review and test it, then sign it and publish it to the official plugin index, and every Kiteline user gets it without an app update.

## FAQ

**Can this get my Claude or Codex account banned?**
Kiteline doesn't sign in to any AI service, doesn't use your subscription's tokens and never calls a model API, so it doesn't change how your agents talk to their providers. Your agents keep running on your computer under your own account, exactly as before. Kiteline reads the transcripts they write and hands your words to the same session through interfaces the agent itself offers.

**Does my code go through your servers?**
On the same network, no: the phone talks to your computer directly over HTTPS, pinned to a certificate your computer issued at pairing. From another network Kiteline first tries a direct peer-to-peer connection and only falls back to the relay when that fails. Everything is end-to-end encrypted; the relay can't read it and doesn't store it. See [Remote access](guide/user/remote-access.md).

**Do I have to change how I work?**
No. Keep starting sessions in VS Code or the terminal. Kiteline finds them on its own. You can also start a task right in Kiteline and let it run in the background, with no VS Code window. Sessions you start in a terminal yourself need to run inside tmux to accept replies from the phone.

**Is there an Android app?**
Use the Kiteline WeChat Mini Program: scan the [code under Install](#install) with WeChat. Native apps are available for iPhone, iPad and Apple Watch.

**Can I use it with agents on a server?**
Yes. Install Kiteline on the server with `--service`, or add the server as a Remote-SSH host in the desktop app and Kiteline deploys a small read-only watcher over SSH (Python 3.8+ standard library only).

**How is this different from Claude Code's Remote Control?**
Remote Control continues one Claude Code session in the Claude app. Kiteline shows every agent on every computer in one list, and adds lock-screen and Apple Watch approvals, screenshots and test reports from the agent, to-dos, goals, group chats between sessions, a code editor with Git and a terminal.

More answers in the [FAQ](guide/user/faq.md).

## Documentation

- [Install and first run](guide/user/install.md)
- [Supported agents and how each one connects](guide/user/agents.md)
- [Approvals, plans and questions](guide/user/approvals.md)
- [Remote access](guide/user/remote-access.md)
- [Privacy and security](guide/user/privacy.md)
- [FAQ](guide/user/faq.md)
- Building a plugin for another agent: [plugin development guide](guide/plugin-development.md)

## Architecture

```mermaid
flowchart LR
    subgraph Devices["iPhone · iPad · Apple Watch"]
        APP["Kiteline app"]
    end
    subgraph Computer["Your computer · macOS / Windows / Linux"]
        HOST["Kiteline host<br/>Swift · Python"]
        WL["Watcher<br/>kiteline-watch.py"]
        UI["VS Code · terminal · tmux"]
    end
    subgraph Servers["Remote-SSH hosts"]
        WR["Watcher over SSH"]
    end
    AG[("Claude Code · Codex · OpenCode<br/>Qwen Code · Kimi Code · CodeBuddy · ZCode · …")]
    PUSH["Push gateway → APNs"]

    APP <-- "HTTPS + SSE · LAN · local CA" --> HOST
    APP <-. "P2P QUIC · relay fallback" .-> HOST
    HOST -- "JSON Lines · stdio" --> WL
    HOST -- "JSON Lines · SSH" --> WR
    WL --> AG
    WR --> AG
    HOST -- "Accessibility · editor URI · PTY" --> UI
    HOST -. "Web Push · RFC 8291 ciphertext" .-> PUSH -.-> APP
```

## Under the hood

- **Session discovery.** A single-file Python watcher (`watcher/kiteline-watch.py`) with **zero third-party dependencies** runs on the local machine and on any Remote-SSH host over plain SSH. It follows Claude Code's session registry and JSONL transcripts, talks to Codex and OpenCode through their own local server protocols, and lets plugins cover other agents, for example through hooks an agent provides. Everything is normalized into one JSON Lines event stream.
- **Input delivery.** Kiteline picks the route by where the session lives, and reports why rather than deliver to the wrong place:
  - **Claude Code**: a small plugin, marked as Kiteline's and placed in Claude Code's own plugin folder, receives messages, approvals and answers inside the session and submits them as the user. No window switching, no simulated keystrokes, and it works with the computer locked.
  - **Background sessions**: the watcher runs the agent's CLI in the background on the computer that holds the project, with the same network settings as in VS Code; one click moves the session into VS Code.
  - **VS Code sessions opened before the update**: still delivered through the front end. Kiteline finds the right window through the Accessibility API, opens the extension's own `vscode://anthropic.claude-code/open` URI to select the session, checks it and then submits.
  - **CLI sessions in tmux**: the watcher drives them directly.
  - **Codex and OpenCode**: replies, approvals and answers go over their native protocols.
- **Transport and pairing.** The phone talks to the host over HTTPS on the local network. Each computer has its own root CA, and X.509 name constraints limit it to private address ranges. Live state is streamed as Server-Sent Events, and the computer is found automatically via Bonjour / mDNS. Pairing uses a 6-digit code, or a QR code that carries a one-time token and the CA fingerprint.
- **End-to-end encrypted notifications.** Payloads are encrypted on the computer with Web Push (RFC 8291 `aes128gcm`, VAPID per RFC 8292). They are decrypted only on the device, by a notification service extension. The push gateway only ever relays ciphertext to APNs.
- **Remote access** (closed-source component). Built with Rust and [iroh](https://github.com/n0-computer/iroh): QUIC connections addressed by device public keys, NAT hole punching with relay fallback, and path migration between Wi-Fi and cellular without dropping the session. Only paired devices can connect.
- **Signed plugins.** Agents beyond the built-ins are distributed through an Ed25519-signed index. Each manifest declares capabilities (view, reply, approve, answer, interrupt, …) and the permissions it needs, and every client renders exactly what an agent supports.
- **On-device speech.** Hold-to-talk transcription runs locally with [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) and the Fun-ASR-Nano model, so audio never leaves your own devices.
- **Live Activities.** The iPhone reports its ActivityKit push-to-start token and each activity’s update token to the computer. The computer starts one per round of work, coalesces updates (a new waiting session goes out at once, everything else at most every 8 seconds) and ends it after 90 idle seconds, sending through the push gateway to APNs’ `liveactivity` channel. Apple requires this content to be plaintext, so it carries only session titles and status.
- **Read-only sharing.** While something is shared, the computer opens a separate local-network HTTP port that serves only `/g/` (closed when nothing is shared). The page polls a snapshot every 8 seconds with an ETag; snapshots are built from the session record on demand, leave out reasoning, images and key info, and never pass through a server.
- **World mode.** A [three.js](https://threejs.org) scene shared by every platform and rendered from the same state stream.
- **Flow Board.** Also three.js, on the same host protocol. Cards are thin slabs with canvas textures; each line kind is one `LineSegments` buffer written as a ring, so the line count stays bounded. Base lines use normal blending so hundreds of them stay a faint grey, while only the lit lines (up to 320) and the particles (one shader-driven `Points`, up to 1,500) are additive. An automatic camera pans and zooms to the busiest card — straight on, in 2D — and lists the calls that just passed through it.

## Tech stack

| Component | Technology | Size |
|---|---|---|
| Mac host | Swift, SwiftUI, AppKit; [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for terminals | ~26k lines |
| Shared UI (Mac and iPhone) | SwiftUI module `KitelineKit` | ~42k lines |
| Session watcher | Python 3, standard library only | ~13k lines |
| Windows and Linux host | Python 3.10+, cryptography, zeroconf, sherpa-onnx | ~17k lines |
| Windows and Linux window | C#, .NET 10, [Avalonia](https://avaloniaui.net) | ~34k lines |
| Code editor | [CodeMirror 6](https://codemirror.net) | |
| World mode and Flow Board | [three.js](https://threejs.org) | |
| Remote access *(not in this repo)* | Rust, iroh (QUIC) | |

## Screenshots

![Mac app: session groups along the top, two sessions side by side, a plan waiting for approval and two sessions messaging each other](assets/images/mac-main-en.jpg)

<table>
<tr>
<td width="58%"><img src="assets/images/mac-trace-en.jpg" alt="Execution trace"><br><sub><b>Execution trace.</b> Agents, turns and steps on a timeline, model calls and tool calls in different colors, a jump to the first error, and replay.</sub></td>
<td width="42%"><img src="assets/images/mac-browser-en.jpg" alt="Agent browser"><br><sub><b>Agent browser.</b> When an agent drives a web page, a live preview appears in the corner of the session. Enlarge it, or take over.</sub></td>
</tr>
</table>

![Session terminal: when an agent needs a terminal, its command runs in a tab of the session's own terminal, labelled with the device](assets/images/mac-terminal-en.jpg)

![World mode on the Mac](assets/images/mac-world-en.jpg)

![Flow Board: every session on one screen, each tool call a line, light running along it as the call happens](assets/images/flow-board-en.jpg)

<table>
<tr>
<td><img src="assets/images/mac-g-pick-panel-en.jpg" alt="Start a group chat"></td>
</tr>
</table>

<sub>Every app is available in English and Simplified Chinese, and follows your system language by default.</sub>

<!-- gallery:start -->

## Every screen, every feature

Screens are framed by device: iPhone, iPad, Apple Watch and the desktop window. All shots come from the real app with demo data.

### In motion

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/anim/en/link-approve.webp" width="360" alt="Approve a plan on the watch, the phone follows"><br><sub>Approve a plan on the watch, the phone follows</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/anim/en/ipad-browser.webp" width="400" alt="iPad columns: the agent&#x27;s browser testing live beside the conversation"><br><sub>iPad columns: the agent&#x27;s browser testing live beside the conversation</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/anim/en/iphone-approve.webp" width="230" alt="One tap to allow, the agent carries on"><br><sub>One tap to allow, the agent carries on</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/anim/en/iphone-plan.webp" width="230" alt="Review the plan, approve it"><br><sub>Review the plan, approve it</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/anim/en/iphone-question.webp" width="230" alt="Answer the agent&#x27;s question"><br><sub>Answer the agent&#x27;s question</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/anim/en/iphone-browser.webp" width="230" alt="The agent tests in a browser, live view comes back"><br><sub>The agent tests in a browser, live view comes back</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/anim/en/iphone-tabs.webp" width="230" alt="Projects, to-dos, overview, one tap away"><br><sub>Projects, to-dos, overview, one tap away</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/anim/en/mac-ar.webp" width="500" alt="AR mode: click a window, it floats to you, reply right there"><br><sub>AR mode: click a window, it floats to you, reply right there</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/anim/en/iphone-world.webp" width="230" alt="World mode: the camera moves through the campus"><br><sub>World mode: the camera moves through the campus</sub></td>
</tr></table>

### Sessions

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-home.webp" width="220" alt="Every session in one list, the ones waiting for you on top"><br><sub>Every session in one list, the ones waiting for you on top</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-home-agent.webp" width="220" alt="Grouped by agent"><br><sub>Grouped by agent</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-home-source.webp" width="220" alt="Grouped by computer, several computers at once"><br><sub>Grouped by computer, several computers at once</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-menu.webp" width="220" alt="The session tools: search, files, changes, tests"><br><sub>The session tools: search, files, changes, tests</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-agentinfo.webp" width="220" alt="Agent details: type, version, plugin, what it can do"><br><sub>Agent details: type, version, plugin, what it can do</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-machine.webp" width="220" alt="Computer details: system, memory, disk, running sessions"><br><sub>Computer details: system, memory, disk, running sessions</sub></td>
</tr></table>

### Approvals, plans and questions

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-perm.webp" width="220" alt="Read the full command, then allow or deny"><br><sub>Read the full command, then allow or deny</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-plan.webp" width="220" alt="Review the plan an agent drew up, approve or keep planning"><br><sub>Review the plan an agent drew up, approve or keep planning</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-question.webp" width="220" alt="Answer the agent&#x27;s question"><br><sub>Answer the agent&#x27;s question</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-voice.webp" width="220" alt="Hold to talk, like a voice message"><br><sub>Hold to talk, like a voice message</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-working.webp" width="220" alt="Follow every step: thinking, commands, edits"><br><sub>Follow every step: thinking, commands, edits</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-panel.webp" width="220" alt="Photos, files, quick replies, ask for a screenshot"><br><sub>Photos, files, quick replies, ask for a screenshot</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-mode.webp" width="220" alt="Permission modes: manual, auto-edit, plan, auto"><br><sub>Permission modes: manual, auto-edit, plan, auto</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-model.webp" width="220" alt="Switch model and thinking level, takes effect at once"><br><sub>Switch model and thinking level, takes effect at once</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-share.webp" width="220" alt="A read-only link so a teammate can watch a session"><br><sub>A read-only link so a teammate can watch a session</sub></td>
</tr></table>

### More than one agent

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-codex.webp" width="220" alt="Codex: the same approvals and progress"><br><sub>Codex: the same approvals and progress</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-opencode.webp" width="220" alt="OpenCode: in the same list as Claude Code"><br><sub>OpenCode: in the same list as Claude Code</sub></td>
</tr></table>

### Screenshots when done, reports when tested

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-cart.webp" width="220" alt="The agent tests in a browser and sends screenshots back"><br><sub>The agent tests in a browser and sends screenshots back</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-tasks.webp" width="220" alt="A task list the agent ticks off"><br><sub>A task list the agent ticks off</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-deploy.webp" width="220" alt="What only you can do, kept as to-dos and key info"><br><sub>What only you can do, kept as to-dos and key info</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-bench.webp" width="220" alt="Progress of long runs such as load tests"><br><sub>Progress of long runs such as load tests</sub></td>
</tr></table>

### Overview and usage

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-overview.webp" width="220" alt="Overview: limits, stats, today"><br><sub>Overview: limits, stats, today</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-today.webp" width="220" alt="Today: what got done, what it cost"><br><sub>Today: what got done, what it cost</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-usage.webp" width="220" alt="Usage by model, project and day"><br><sub>Usage by model, project and day</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-me.webp" width="220" alt="Settings: appearance, language, translation"><br><sub>Settings: appearance, language, translation</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-widgets.webp" width="220" alt="Home Screen widgets: sessions and limits"><br><sub>Home Screen widgets: sessions and limits</sub></td>
</tr></table>

### Projects and code

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-projects.webp" width="220" alt="Projects: oversee every project"><br><sub>Projects: oversee every project</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-files.webp" width="220" alt="Browse project files"><br><sub>Browse project files</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-changes.webp" width="220" alt="Changed files, commit right here"><br><sub>Changed files, commit right here</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-codediff.webp" width="220" alt="Code diff"><br><sub>Code diff</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-gitlog.webp" width="220" alt="Commit history"><br><sub>Commit history</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-history.webp" width="220" alt="Past sessions, by project or agent"><br><sub>Past sessions, by project or agent</sub></td>
</tr></table>

### To-dos, new tasks and collaboration

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-todos.webp" width="220" alt="To-dos: yours and the agent&#x27;s, kept apart"><br><sub>To-dos: yours and the agent&#x27;s, kept apart</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-newtask.webp" width="220" alt="New task: pick project, computer and agent"><br><sub>New task: pick project, computer and agent</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-schedules.webp" width="220" alt="Scheduled tasks: hourly, daily, weekly"><br><sub>Scheduled tasks: hourly, daily, weekly</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-inbox.webp" width="220" alt="Notification history"><br><sub>Notification history</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-group.webp" width="220" alt="Group chat: let sessions talk to each other"><br><sub>Group chat: let sessions talk to each other</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-world.webp" width="220" alt="World mode: every session in one pixel campus"><br><sub>World mode: every session in one pixel campus</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/ip-settings.webp" width="220" alt="Settings"><br><sub>Settings</sub></td>
</tr></table>

### iPad

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/pad-columns.webp" width="440" alt="Two sessions side by side"><br><sub>Two sessions side by side</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/pad-perm.webp" width="440" alt="Approve a command"><br><sub>Approve a command</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/pad-codex.webp" width="440" alt="A Codex session"><br><sub>A Codex session</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/pad-question.webp" width="440" alt="Answer a question"><br><sub>Answer a question</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/pad-working.webp" width="440" alt="Live progress"><br><sub>Live progress</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/pad-today.webp" width="440" alt="Today"><br><sub>Today</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/pad-todos.webp" width="440" alt="To-dos"><br><sub>To-dos</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/pad-world.webp" width="440" alt="World mode"><br><sub>World mode</sub></td>
</tr></table>

### Apple Watch

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/w-now.webp" width="160" alt="Approve or deny from your wrist"><br><sub>Approve or deny from your wrist</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/w-plan.webp" width="160" alt="Review a plan"><br><sub>Review a plan</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/w-question.webp" width="160" alt="Answer a question"><br><sub>Answer a question</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/w-list.webp" width="160" alt="Session list"><br><sub>Session list</sub></td>
<td align="center" valign="top"><img src="assets/images/gallery/en/w-usage.webp" width="160" alt="Usage and limits"><br><sub>Usage and limits</sub></td>
</tr></table>

### Desktop: the new layout

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/mac-n-main.webp" width="900" alt="Projects, sessions and files laid out like VS Code"><br><sub>Projects, sessions and files laid out like VS Code</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/mac-n-sessions.webp" width="900" alt="Session list: filters, groups, status at a glance"><br><sub>Session list: filters, groups, status at a glance</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/mac-n-files.webp" width="900" alt="Browse and edit project files"><br><sub>Browse and edit project files</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/mac-n-git.webp" width="900" alt="Git: changes, commits, branches"><br><sub>Git: changes, commits, branches</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/mac-n-projsess.webp" width="900" alt="Each project&#x27;s sessions in its own panel"><br><sub>Each project&#x27;s sessions in its own panel</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/mac-n-favorites.webp" width="900" alt="Favorites: jump back to the original message"><br><sub>Favorites: jump back to the original message</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/mac-n-todos.webp" width="900" alt="To-dos"><br><sub>To-dos</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/mac-n-today.webp" width="900" alt="Today, in a floating window"><br><sub>Today, in a floating window</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/mac-n-usage.webp" width="900" alt="Usage: limits, cost, by model"><br><sub>Usage: limits, cost, by model</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/mac-n-layout.webp" width="900" alt="Arrange the layout your way"><br><sub>Arrange the layout your way</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/mac-n-newtab.webp" width="900" alt="Start a session right in a tab"><br><sub>Start a session right in a tab</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/mac-n-light.webp" width="900" alt="VS Code style color schemes, dark and light"><br><sub>VS Code style color schemes, dark and light</sub></td>
</tr></table>

### Desktop

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/mac-main.webp" width="900" alt="Session groups, split view, sessions messaging each other"><br><sub>Session groups, split view, sessions messaging each other</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/mac-trace.webp" width="900" alt="Execution trace: timeline, stats, jump to the error"><br><sub>Execution trace: timeline, stats, jump to the error</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/mac-terminal.webp" width="900" alt="Session terminal: commands run in a tab named for the device"><br><sub>Session terminal: commands run in a tab named for the device</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/mac-browser.webp" width="900" alt="Agent browser: live view, enlarge or take over"><br><sub>Agent browser: live view, enlarge or take over</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/mac-world.webp" width="900" alt="World mode"><br><sub>World mode</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/mac-flow.webp" width="900" alt="Flow board"><br><sub>Flow board</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/mac-group.webp" width="900" alt="One-click group chat"><br><sub>One-click group chat</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/mac-plugins.webp" width="900" alt="Plugins: one signed plugin per agent"><br><sub>Plugins: one signed plugin per agent</sub></td>
</tr></table>

### AR mode

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/ar-space.webp" width="900" alt="Sessions float in space, the most active nearest"><br><sub>Sessions float in space, the most active nearest</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/ar-sea.webp" width="900" alt="Five flowing backgrounds, or your own video"><br><sub>Five flowing backgrounds, or your own video</sub></td>
</tr></table>

<table><tr>
<td align="center" valign="top"><img src="assets/images/gallery/en/ar-aurora.webp" width="900" alt="Reply right in a floating window, by voice too"><br><sub>Reply right in a floating window, by voice too</sub></td>
</tr></table>

<!-- gallery:end -->

## Open source and subscription

**Build it yourself.** All the source code is public in this repository. If you have the time and enjoy building things, you're welcome to build, modify and extend it under the terms of the AGPL-3.0. Suggestions are always welcome through Issues.

**Use the official build.** If you'd rather not spend time and tokens building and maintaining it yourself, download the official build from the [website](https://tars.betac.cn/download/):

- When your phone and computer are on the same Wi-Fi, every feature is free.
- To use Kiteline from any network, subscribe to Kiteline Pro in the iPhone app. It costs about as much as a cup of bubble tea a month and pays for server renewal and maintenance.

## Repository layout

```text
.
├── Sources/                Mac host (Swift, SwiftUI)
├── Resources/              Mac resources, world mode (three.js), code editor (CodeMirror)
├── KitelineKit/            SwiftUI components shared by the Mac and iPhone apps
├── watcher/
│   └── kiteline-watch.py   Session watcher, runs locally or over SSH (stdlib only)
├── desktop/
│   ├── kiteline/           Windows and Linux host (Python)
│   ├── client/             Windows and Linux native window (C#, Avalonia)
│   └── packaging/          PyInstaller and tarball packaging
├── plugins/                Agent plugins distributed separately from the app
├── PLUGINS.md              Supported agents per platform (generated)
├── tools/plugin_check.py   Test a plugin on your own machine
├── tests/                  Integration tests for the HTTP API and the watcher
├── build.sh · install.sh   Mac build and install
└── docs/                   Plugin development guide, agent integration notes, world mode
```

Not included: the remote access component, the iPhone, iPad and Apple Watch app shells (pairing, settings, widgets, Xcode project) and the servers (relay, push gateway, statistics). A build from this repository works on your local network. For remote access, use the official build; see [Open source and subscription](#open-source-and-subscription).

## Build from source

### Mac

Requirements:

- macOS 14 or later.
- Xcode, or just the Command Line Tools (`xcode-select --install`).
- Python 3, which the session watcher runs on.

```bash
git clone https://github.com/hon6/kiteline.git
cd kiteline
./install.sh                 # build, install to /Applications/Kiteline.app and launch
./install.sh my-server       # also watch sessions on Remote-SSH hosts (passwordless ssh)
./build.sh                   # build only → dist/Kiteline.app
```

A build from source replaces an installed official Kiteline and keeps its data and pairings. To make that possible, a few runtime identifiers keep the project's early names:

- the data folder `~/Library/Application Support/TARS`;
- the executable name;
- the watcher installed as `~/.ccpulse/ccpulse-watch.py` on each machine.

The app is signed with a self-signed identity created on the first build, so macOS permissions carry over between rebuilds.

Optional offline speech recognition: copy `libsherpa-onnx-c-api.dylib` and `libonnxruntime.dylib` from the `sherpa-onnx-core` 1.13.8 macOS arm64 wheel into `vendor/sherpa-onnx/lib/`. Without them, Kiteline falls back to the system speech recognizer.

### Windows and Linux

Requirements: Python 3.10 or later.

```bash
cd desktop
python3 -m venv .venv && . .venv/bin/activate      # Windows: .venv\Scripts\activate
pip install -r requirements.txt
python -m kiteline               # opens the console in your browser, adds a tray icon
python -m kiteline --headless    # servers without a desktop: prints the pairing code
```

Packages:

- Linux tarball: `bash desktop/packaging/build-linux.sh`.
- Windows zip: `desktop\packaging\build-windows.ps1`.
- Native window (.NET 10): run `bash desktop/client/publish.sh linux-x64 win-x64` first, then package with `KITELINE_WITH_CLIENT=1`.

### Pair your phone

1. Install Kiteline from the [App Store](https://apps.apple.com/app/id6825244029).
2. Open **Phone Access** on the computer: the menu bar icon on Mac, the tray or the console on Windows and Linux.
3. Scan the QR code. No account is needed.

## Privacy and security

- **No AI credentials.** Kiteline never signs in to Claude or any other AI service, never reads or forwards API keys or session tokens, never calls a model API and never modifies the agents themselves.
- **Your devices only.** Conversations and code travel only between your computer and your phone, end-to-end encrypted.
- **Usage statistics.** Every 15 minutes the computer sends a summary to the Kiteline server: device types and versions, which agents and models are used, token counts and the display name you set, with all IDs hashed. It never includes conversations, code, file names, paths or session titles. Turn it off in Settings → **Send usage statistics** (`Sources/UsageStats.swift`, `desktop/kiteline/stats.py`).
- **Read-aloud.** If you choose Microsoft voices for reading replies aloud (optional, via edge-tts), the text being read is sent to Microsoft to be synthesized.

## Contributing

Issues, discussions and pull requests are welcome, especially **plugins for new agents** (see the [plugin development guide](guide/plugin-development.md)). Before opening a pull request, please read [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Copyright © 2026 hon6. Licensed under the [GNU Affero General Public License v3.0](LICENSE). If you distribute a modified version, or run one as a network service for others, you must make your source code available under the same license. For other licensing arrangements, contact hon6@foxmail.com.

"Kiteline" and the paper-kite logo identify the official app; please don't use them for modified versions. Agent names and logos (from [LobeHub Icons](https://github.com/lobehub/lobe-icons), MIT) belong to their respective owners and are used only to show which tool a session comes from. Kiteline is not affiliated with or endorsed by Anthropic, OpenAI, Anysphere or any other agent vendor. Third-party licenses are listed in `Resources/ThirdPartyNotices.json`.

<div align="center"><br><a href="https://tars.betac.cn"><b>tars.betac.cn</b></a></div>
