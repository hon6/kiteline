# Supported agents

[简体中文](agents.zh-CN.md)

Kiteline never changes an agent's configuration and never touches its login. It follows each agent through what the agent already offers: the transcripts it writes on disk, its own local server or IPC, extension points such as hooks or an editor URI, or the terminal it runs in.

| Agent | Where | What works from your phone |
|---|---|---|
| **Claude Code** | VS Code extension (local and Remote-SSH windows), terminal | Everything: follow, reply, approve, answer, switch permission mode, model and reasoning effort, compact the context, set goals |
| **Codex** | Terminal, VS Code extension, ChatGPT desktop app | Everything, through Codex's own interfaces, with no setup; Codex doesn't need to be in the foreground |
| **OpenCode** | Terminal | Everything, through a plugin Kiteline installs automatically (restart OpenCode once) |
| **DeepSeek Harness** | Desktop app, command line | Everything, once you turn it on under **Settings → Plugins** |
| **Qwen Code** | Terminal | Reply and approve when it runs inside tmux; view only otherwise |
| **Proma** | Desktop app | View only |

The full matrix per platform is in [PLUGINS.md](../../PLUGINS.md).

## Notes per agent

- **Claude Code in VS Code.** Kiteline types into the same session's input box, the way you would. Before submitting, it checks that the focused tab is the right session, and stops with an error rather than send to the wrong one.
- **Claude Code in a terminal.** Run it inside tmux to accept replies from the phone, for example `tmux new -A -s claude claude`. Sessions outside tmux are still shown.
- **DeepSeek Harness.** It has no interface for third-party tools, so Kiteline has to read its local connection key (not a model API key). That's why it stays off until you've read how it connects and turned it on.
- **Goals (`/goal`).** Claude Code 2.1.139 or later and Codex in a terminal. Codex goals can also be paused and resumed. Sessions in the Codex desktop app and VS Code extension show goal progress; set the goal in Codex.

## Why some agents are view-only

When an agent offers no way for another program to reply on your behalf, Kiteline still shows its sessions and full transcripts, but it won't simulate input or patch the agent to take control. The app tells you why a session is view-only and how to enable more, for example by starting the CLI in tmux.

## Adding an agent

Agents beyond the built-ins ship as signed plugins: a manifest plus a small Python module running in the watcher. New plugins reach every user without an app update. See the [plugin development guide](../plugin-development.md).
