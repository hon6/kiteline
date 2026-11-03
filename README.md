<div align="center">

<img src="docs/images/icon.png" width="112" alt="Kiteline">

# Kiteline

### Your coding agents keep working while you're away from the keyboard.

Kiteline watches every Claude Code, Codex, OpenCode and DeepSeek Harness session on your computers and puts them on your iPhone, iPad and Apple Watch: you can see what each agent is doing, approve its requests, answer its questions and send it the next task.

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

![Kiteline: speak a task on your phone, the agent codes, tests and sends back a screenshot](docs/images/hero-en.jpg)

> **Official website: [tars.betac.cn](https://tars.betac.cn)**. Official installers for Mac, Windows and Linux are available there and on [GitHub Releases](https://github.com/hon6/kiteline/releases). The iPhone, iPad and Apple Watch app is on the [App Store](https://apps.apple.com/app/id6825244029).

## See it in action

<table>
<tr>
<td width="50%"><a href="https://tars.betac.cn/assets/video/kiteline-1-en.mp4"><img src="docs/media/demo-en-1.webp" alt="Dispatch by voice, get a screenshot back"></a><br><sub><b>No more coding blind.</b> Send a task by voice; the agent reports back with screenshots.</sub></td>
<td width="50%"><a href="https://tars.betac.cn/assets/video/kiteline-2-en.mp4"><img src="docs/media/demo-en-2.webp" alt="Approve from the lock screen or your watch"></a><br><sub><b>Approve from anywhere.</b> Lock screen, phone or watch; risky commands always ask twice.</sub></td>
</tr>
<tr>
<td width="50%"><a href="https://tars.betac.cn/assets/video/kiteline-3-en.mp4"><img src="docs/media/demo-en-3.webp" alt="Every computer, every agent"></a><br><sub><b>Every computer, every agent.</b> Mac, Windows, Linux and Remote-SSH in one list.</sub></td>
<td width="50%"><a href="https://tars.betac.cn/assets/video/kiteline-4-en.mp4"><img src="docs/media/demo-en-4.webp" alt="Start work on the go"></a><br><sub><b>Start work on the go.</b> Dispatch a task and check today's progress at a glance.</sub></td>
</tr>
</table>

<sub>Click any clip to watch the full video.</sub>

## Highlights

| | |
|---|---|
| **One list for every agent** | Claude Code (VS Code and terminal), Codex, OpenCode, DeepSeek Harness, Qwen Code and more. New agents ship as signed plugins, so supporting one doesn't need an app update. |
| **Approve anywhere** | Permission requests, plan approvals and multiple-choice questions become cards on the lock screen, the phone and the watch. |
| **Reply your way** | Type, hold to talk (on-device speech recognition), attach photos and screenshots, or start a new task in any project. |
| **See the work, not just the chat** | Live steps, commands, diffs, test output and images, plus a code editor with Git and a terminal that runs inside each session. |
| **Task progress** | Each session shows its current stage (for example "2/4 Developing"), and agents can send screenshots and reports straight to your phone. |
| **Goals** | Give a Claude Code or Codex session a goal (`/goal`) from your phone and the agent keeps working, round after round, until it is met. The session list shows which round it is on, the chat shows what the last check said is still missing, and you get a notification when the goal is met, can't be met or stops. |
| **To-dos** | Anything the agent needs *you* to do is picked up from the conversation and tracked until it's done. |
| **Group chats** | Sessions on different computers and projects coordinate with each other through Kiteline. |
| **World mode** | A voxel office where every session is a worker at a desk, so you can see the whole team at a glance. |
| **Flow Board** | Every session on one screen: what each one reads, what it does and where the output goes. Each tool call is a line, and a trail of light runs along it the moment the call happens. |

## Supported agents

| Agent | What you can do from your phone |
|---|---|
| **Claude Code** | Full control: VS Code extension and CLI |
| **Codex** | Full control: CLI, VS Code extension and desktop app |
| **OpenCode** | Full control |
| **Cursor** | Plugin coming soon (source in [`plugins/cursor`](plugins/cursor)) |
| **Qwen Code** | Reply and approve when it runs in tmux; view-only otherwise |
| **DeepSeek Harness** | Full control (opt-in) |
| **Proma** | View only |

The per-platform matrix is in **[PLUGINS.md](PLUGINS.md)**. It is generated from the capabilities each plugin declares and updated with every release.

**Why are some agents view-only?** Kiteline never touches your AI credentials and never modifies an agent. It only acts through interfaces the agent itself offers: its local server or IPC, extension points such as hooks or an editor URI, or the terminal (tmux) it runs in. When an agent offers none of these, Kiteline can still show its sessions and full transcripts from disk, but it won't simulate input or patch the agent to take control. The app tells you why a session is view-only and how to enable more, for example by starting the CLI in tmux. Details are in the [plugin guide](docs/plugin-development.md#why-some-agents-are-view-only).

**Build a plugin.** New agents are added as plugins: a manifest plus a small Python module running in the watcher. The [plugin development guide](docs/plugin-development.md) covers the manifest, the interface and the rules, and `tools/plugin_check.py` lets you test a plugin on your own machine. Open a pull request: we review and test it, then sign it and publish it to the official plugin index, and every Kiteline user gets it without an app update.

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
    AG[("Claude Code · Codex · OpenCode<br/>Qwen Code · DeepSeek Harness · …")]
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
- **Input delivery.** Claude Code has no writable stdin, so Kiteline delivers input through the front end:
  - **VS Code sessions**: Kiteline finds the right window through the Accessibility API, opens the extension's own `vscode://anthropic.claude-code/open` URI to select the session and prefill the prompt, checks the input box and then submits.
  - **CLI sessions in tmux**: the watcher drives them directly.
  - **Other terminal sessions**: Kiteline walks the process tree to the terminal app that hosts the session.
  - **Codex and OpenCode**: replies, approvals and answers go over their native protocols.
- **Transport and pairing.** The phone talks to the host over HTTPS on the local network. Each computer has its own root CA, and X.509 name constraints limit it to private address ranges. Live state is streamed as Server-Sent Events, and the computer is found automatically via Bonjour / mDNS. Pairing uses a 6-digit code, or a QR code that carries a one-time token and the CA fingerprint.
- **End-to-end encrypted notifications.** Payloads are encrypted on the computer with Web Push (RFC 8291 `aes128gcm`, VAPID per RFC 8292). They are decrypted only on the device, by a notification service extension. The push gateway only ever relays ciphertext to APNs.
- **Remote access** (closed-source component). Built with Rust and [iroh](https://github.com/n0-computer/iroh): QUIC connections addressed by device public keys, NAT hole punching with relay fallback, and path migration between Wi-Fi and cellular without dropping the session. Only paired devices can connect.
- **Signed plugins.** Agents beyond the built-ins are distributed through an Ed25519-signed index. Each manifest declares capabilities (view, reply, approve, answer, interrupt, …) and the permissions it needs, and every client renders exactly what an agent supports.
- **On-device speech.** Hold-to-talk transcription runs locally with [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) and the Fun-ASR-Nano model, so audio never leaves your own devices.
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

<table>
<tr>
<td><img src="docs/images/iphone/01-agents.jpg" alt="All agents"></td>
<td><img src="docs/images/iphone/03-approve.jpg" alt="Approve"></td>
<td><img src="docs/images/iphone/06-plan.jpg" alt="Plan approval"></td>
<td><img src="docs/images/iphone/07-live.jpg" alt="Live steps"></td>
<td><img src="docs/images/iphone/02-world.jpg" alt="World mode"></td>
</tr>
<tr>
<td><img src="docs/images/iphone/04-codex.jpg" alt="Codex"></td>
<td><img src="docs/images/iphone/05-voice.jpg" alt="Voice"></td>
<td><img src="docs/images/iphone/08-overview.jpg" alt="Overview"></td>
<td><img src="docs/images/iphone/09-watch.jpg" alt="Apple Watch"></td>
<td><img src="docs/images/iphone/10-remote.jpg" alt="Remote access"></td>
</tr>
</table>

<table>
<tr>
<td width="25%"><img src="docs/images/watch/1-now.jpg" alt="Watch: approve"></td>
<td width="25%"><img src="docs/images/watch/3-question.jpg" alt="Watch: answer"></td>
<td width="25%"><img src="docs/images/watch/4-plan.jpg" alt="Watch: plan"></td>
<td width="25%"><img src="docs/images/watch/5-usage.jpg" alt="Watch: usage"></td>
</tr>
</table>

![Mac app: sessions side by side, a plan waiting for approval and two sessions messaging each other](docs/images/mac-main.jpg)

![World mode on the Mac](docs/images/mac-world.jpg)

![Flow Board: every session on one screen, each tool call a line, light running along it as the call happens](docs/images/flow-board.jpg)

<table>
<tr>
<td width="62%"><img src="docs/images/ipad-split.jpg" alt="iPad split view"></td>
<td width="38%"><img src="docs/images/mac-g-pick-panel.jpg" alt="Start a group chat"></td>
</tr>
</table>

<sub>App Store screenshots shown in Chinese; the apps are fully localized in English.</sub>

## Open source and subscription

Kiteline was built to free developers from waiting on their agents. It began as an internal tool our team relies on every day and has been refined through real development work. We are now opening it up so that more developers can benefit.

There are many remote-control tools available. Every Kiteline feature comes from a real development need: managing multiple agents, picking up to-dos, group chats between sessions, code editing, in-session terminals, world mode and more. Together they cover the full workflow of coding remotely with agents, with the aim of being comprehensive and practical.

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

Issues, discussions and pull requests are welcome, especially **plugins for new agents** (see the [plugin development guide](docs/plugin-development.md)). Before opening a pull request, please read [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Copyright © 2026 hon6. Licensed under the [GNU Affero General Public License v3.0](LICENSE). If you distribute a modified version, or run one as a network service for others, you must make your source code available under the same license. For other licensing arrangements, contact hon6@foxmail.com.

"Kiteline" and the paper-kite logo identify the official app; please don't use them for modified versions. Agent names and logos (from [LobeHub Icons](https://github.com/lobehub/lobe-icons), MIT) belong to their respective owners and are used only to show which tool a session comes from. Kiteline is not affiliated with or endorsed by Anthropic, OpenAI, Anysphere or any other agent vendor. Third-party licenses are listed in `Resources/ThirdPartyNotices.json`.

<div align="center"><br><a href="https://tars.betac.cn"><b>tars.betac.cn</b></a></div>
