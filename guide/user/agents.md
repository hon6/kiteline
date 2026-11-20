# Supported agents

[简体中文](agents.zh-CN.md)

Kiteline never changes an agent's configuration and never touches its login. It follows each agent through what the agent already offers: the transcripts it writes on disk, its own local server or IPC, extension points such as hooks or an editor URI, or the terminal it runs in.

| Agent | Where | What works from your phone |
|---|---|---|
| **Claude Code** | VS Code extension (local and Remote-SSH windows), terminal, or run by Kiteline in the background | Everything: follow, reply, approve, answer, switch permission mode, model and reasoning effort, compact the context, set goals |
| **Codex** | Terminal, VS Code extension, ChatGPT desktop app | Everything, through Codex's own interfaces, with no setup; Codex doesn't need to be in the foreground |
| **OpenCode** | Terminal | Everything, through a plugin Kiteline installs automatically (restart OpenCode once) |
| **DeepSeek Harness** | Desktop app, command line | Everything, once you turn it on under **Settings → Plugins** |
| **Cursor** | Editor, command line | View, reply, approve, interrupt |
| **ZCode** | Desktop app, command line | Everything |
| **Kimi Code** · **Hermes** · **Grok Build** · **CodeBuddy Code** · **Antigravity CLI** | Terminal | Everything: pick one when starting a task and Kiteline runs it in the background (Mac and Linux), or start it in tmux yourself |
| **Qwen Code** | Terminal | View, reply, approve, interrupt (background or tmux) |
| **Muse Code** · **pi** | Terminal | View, reply, interrupt (background or tmux) |
| **trae-agent** | Terminal | View tasks and full records; send tasks from your phone |
| **WorkBuddy** | Desktop app | View and reply on the Mac; view only elsewhere |
| **Proma** · **Antigravity desktop app** | Desktop app | View only |

The full matrix per platform is in [PLUGINS.md](../../PLUGINS.md).

## Notes per agent

- **Claude Code in VS Code.** Kiteline places a small plugin, marked as its own, in Claude Code's plugin folder. It receives your messages, approvals and answers inside the session: no window switching, and it works with the computer locked. For sessions that were open before that plugin loaded, Kiteline still types into the same session's input box the way you would; before submitting, it checks that the focused tab is the right session, and stops with an error rather than send to the wrong one.
- **Claude Code in the background.** On a Mac or Linux computer, new tasks and resumed sessions run Claude Code in the background by default, with no VS Code window. Click **Open in VS Code** on the session's tab bar when you want to read the code. For hosts connected over SSH, turn it on per device under **Settings → Sources** after checking the network exit.
- **Claude Code in a terminal.** A session you start in a terminal yourself needs to run inside tmux to accept replies from the phone, for example `tmux new -A -s claude claude`. Sessions outside tmux are still shown.
- **Other command-line agents.** Kimi Code, Grok Build, Hermes, Muse Code, the Antigravity CLI, CodeBuddy Code, Qwen Code, pi and trae-agent can be picked when you start a task on Mac or Linux; Kiteline runs them in the background, so you don't need to open tmux yourself.
- **DeepSeek Harness.** It has no interface for third-party tools, so Kiteline has to read its local connection key (not a model API key). That's why it stays off until you've read how it connects and turned it on.
- **Goals (`/goal`).** Claude Code 2.1.139 or later and Codex in a terminal. Codex goals can also be paused and resumed. Sessions in the Codex desktop app and VS Code extension show goal progress; set the goal in Codex.

## Why some agents are view-only

When an agent offers no way for another program to reply on your behalf, Kiteline still shows its sessions and full transcripts, but it won't simulate input or patch the agent to take control. The app tells you why a session is view-only and how to enable more, for example by picking the agent when you start a task, or by starting the CLI in tmux.

## Adding an agent

Agents beyond the built-ins ship as signed plugins: a manifest plus a small Python module running in the watcher. New plugins reach every user without an app update. See the [plugin development guide](../plugin-development.md).
