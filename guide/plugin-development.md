# Plugin development guide

**English** · [简体中文](plugin-development.zh-CN.md)

Kiteline supports a new coding agent through a **plugin**: a small Python module that tells Kiteline where the agent keeps its sessions, how to read them, and what it can do with them. The phone, watch and desktop apps never need an update for a new agent. They only render a unified format.

The current list of agents and what each one supports is in [PLUGINS.md](../PLUGINS.md). This guide explains how plugins work and how to write one. It also explains how to contribute a plugin to this repository.

## Why some agents are view-only

Kiteline follows three rules for every agent:

1. **It never touches your AI credentials.** It doesn't sign in to any AI service, doesn't read or forward API keys or session tokens, and never calls a model API.
2. **It never modifies the agent itself.** No patched binaries, no injected code, and no private hooks the agent doesn't offer.
3. **It only uses what the agent offers on your own computer.**

Within those rules, there are four ways to reach a session, in this order of preference:

| Channel | What it allows | Examples |
|---|---|---|
| The agent's own local interface (local server, IPC, RPC) | Full control: reply, approve, answer, interrupt | Codex, OpenCode, DeepSeek Harness |
| Extension points the agent provides (editor URI, hooks) | Reply and approve | Claude Code's VS Code extension, Cursor hooks |
| The terminal the session runs in (tmux pane, Windows console) | Reply and approve | Claude Code, Qwen Code and Cursor CLI in tmux |
| Session files the agent writes to disk | **View only** | Proma; any CLI session outside tmux |

If an agent offers none of the first three, Kiteline can still show its sessions, steps and transcripts, but it can't act on them. Simulating keystrokes into an arbitrary window, or patching the agent, would break the rules above. It would also risk sending input to the wrong place. A view-only session shows the reason in the input box, for example "Qwen Code isn't running in tmux, so this session is view-only".

An agent sometimes keeps a local secret that its own UI uses but that isn't an interface for third parties. DeepSeek Harness is one example. A plugin may read such a secret only as an **opt-in**: it stays off until the user reads an explanation in Settings → Plugins and turns it on.

## How a plugin fits in

```text
iPhone · iPad · Watch · desktop UI     render the unified format only
            ▲ snapshots, items, pending cards      ▼ send / key / answer / close
Kiteline host (Mac app or Windows/Linux host + watcher)
            provides capabilities: files, processes, local sockets, tmux, UI actions, reversible installs
            ▲ unified format                       ▼ calls into the plugin
Plugin (one per agent)                 knows where sessions live and how to translate them
            ▲▼
The agent (CLI, editor extension, desktop app)
```

A plugin runs inside the session watcher (`watcher/kiteline-watch.py`). The watcher runs on the local computer and on every Remote-SSH host. The plugin never draws UI and never touches the keyboard or clipboard directly. If it needs a UI action, it returns an action list for the host to perform safely.

## Layout

```text
plugins/<id>/
├── plugin.json   manifest
├── plugin.py     implementation (Python 3, standard library only)
└── assets/       optional components installed into the agent (removed again when the plugin is turned off)
```

The folder name must equal the `id` in the manifest.

## Manifest (`plugin.json`)

```json
{
  "id": "qwen-code",
  "name": "Qwen Code",
  "version": "1.0.2",
  "summary": "通义千问的命令行编程 agent：查看会话、状态和完整对话；在 tmux 中运行时可回复和确认",
  "summaryEn": "Qwen's command-line coding agent: view sessions, status and full conversations; reply and confirm when it runs in tmux",
  "needs": ["fs.read", "fs.tail", "proc", "term.tmux"],
  "detect": {"paths": ["~/.qwen"], "commands": ["qwen"]},
  "support": {
    "mac":     {"cli": {"abilities": ["view", "reply", "approve", "interrupt"], "verified": false, "note": "回复和确认需要 Qwen Code 在 tmux 中运行"}},
    "windows": {"cli": {"abilities": ["view"], "verified": false, "note": "Windows 上没有 tmux，只能查看"}},
    "linux":   {"cli": {"abilities": ["view", "reply", "approve", "interrupt"], "verified": true}}
  }
}
```

| Field | Meaning |
|---|---|
| `id`, `name`, `version` | Identifier (same as the folder), display name, semantic version. A plugin with the same `id` as a built-in one replaces it only if its version is higher. |
| `summary`, `summaryEn` | One line for the plugin page, in Chinese and English. |
| `needs` | Host capabilities the plugin uses (see below). A host that lacks one won't load the plugin and asks the user to update Kiteline. |
| `detect` | How to tell whether the agent is installed when the plugin isn't loaded yet: any of these paths or commands exists. |
| `support` | What works on each platform (`mac`, `windows`, `linux`) and form (`cli`, `vscode`, `desktop`): abilities from `view`, `reply`, `approve`, `answer`, `interrupt`, whether **you actually tested it** (`verified`), and an optional note. [PLUGINS.md](../PLUGINS.md) is generated from this. |
| `caps` | Extra controls beyond view, reply, approve and interrupt: `mode`, `model`, `compact`, `subagents`, `tests`, `close`. |
| `mark`, `speaker` | Monochrome logo (SVG paths on a 24×24 canvas, `[{"d": "M…", "opacity": 1}]`) and how the agent is named in messages ("Qwen wants to run Bash"). |
| `minApp` | Minimum versions: `mac`, `desktop`, `ios`. Use it only if you depend on something newer. |
| `optIn`, `optInEn` | Required if the plugin uses something the agent doesn't offer to third parties (for example `secret.read`). This is the explanation shown before the user turns it on. |

### Host capabilities (`needs`)

| Capability | Provides |
|---|---|
| `locate` | Where the agent is installed and which version |
| `fs.read`, `fs.tail` | Read files and directories; follow append-only transcript files (offsets, truncation) |
| `db.read` | Open SQLite databases read-only |
| `proc`, `proc.pipe` | List processes, liveness, parent chain; run a child process over stdin/stdout |
| `net.connect`, `net.ws`, `net.http`, `net.sse` | Local Unix sockets, named pipes and TCP, WebSocket, HTTP and event streams (local only) |
| `term.tmux` | Send text and keys to the tmux pane a session runs in |
| `install.file` | Install a marked component into the agent; removed when the plugin is turned off |
| `secret.read` | Read a secret the agent stores locally (opt-in only) |
| `ui.keys` | Return a UI action list (focus a window, then press keys); the host verifies the foreground before every step |

The full specification, in Chinese, is in [agent-plugins.md](agent-plugins.md).

## Implementation (`plugin.py`)

`plugin.py` exports `create(kl)` and returns an instance of `kl.AgentPlugin`. `kl` is the watcher module itself. It gives you the base class and helpers such as `kl.HOME`, `kl.read_text`, `kl.pid_alive`, `kl.parse_ts`, `kl.clip`, `kl.find_tmux_pane`, `kl.tmux_send` and `kl.tool_brief`.

A minimal view-only plugin for an agent that keeps one JSON file per running session and a JSONL transcript:

```python
import glob, json, os


def create(kl):
    ROOT = os.path.join(kl.HOME, ".acme")

    def acme_normalize(offset, entry):
        """One transcript line → conversation items (t: user / text / thinking / tool / result)."""
        if not isinstance(entry, dict):
            return []
        base = {"id": "%d.0" % offset, "ts": kl.parse_ts(entry.get("time"))}
        if entry.get("role") == "user":
            return [dict(base, t="user", text=kl.clip(entry.get("text") or "", kl.USER_TEXT_MAX)[0])]
        if entry.get("role") == "assistant":
            return [dict(base, t="text", text=kl.clip(entry.get("text") or "", kl.ASSISTANT_TEXT_MAX)[0])]
        return []

    class Acme(kl.AgentPlugin):
        name = "Acme"
        read_only = "Acme has no remote-control interface, so sessions are view-only"
        normalize = staticmethod(acme_normalize)   # a class body can't read an outer variable of the same name

        def detect(self):
            return {"installed": os.path.isdir(ROOT), "forms": {"cli": ""}}

        def sessions(self):
            out = []
            for path in glob.glob(os.path.join(ROOT, "sessions", "*.json")):
                info = json.loads(kl.read_text(path) or "{}")
                if not kl.pid_alive(int(info.get("pid") or 0)):
                    continue
                out.append({
                    "sessionId": info["id"], "agent": "acme",
                    "title": info.get("title") or info["id"][:8],
                    "cwd": info.get("cwd") or "", "cwdShort": kl.display_cwd(info.get("cwd") or ""),
                    "activity": "busy" if info.get("busy") else "idle",
                    "transcriptPath": os.path.join(ROOT, "transcripts", info["id"] + ".jsonl"),
                    "updatedAt": int(os.path.getmtime(path) * 1000),
                    "readOnly": True,
                })
            return out

    return Acme()
```

**Snapshot.** Each session is a dictionary. Required fields:

- `sessionId`, `agent`, `title`, `cwd`;
- `activity`: `busy`, `idle` or `waiting`.

Common optional fields: `transcriptPath` (the host then follows the file, pages history, searches and loads images for you), `message` (latest reply preview), `pendingTool` / `pendingOptions` (approval cards), and `readOnly` with `readOnlyReason` / `readOnlyReasonEn`.

**Conversation items.** `normalize(offset, entry)` turns one transcript line into items:

- `user`, `text` and `thinking` carry `text`;
- `tool` carries `name`, `brief`, `input` and `toolId`;
- `result` carries `toolId`, `text` and `isError`.

Map the agent's tool names to familiar ones (`Bash`, `Read`, `Edit`, `Write`, `Grep`, `TodoWrite`…) so diffs and task lists render. Unknown item types are shown as plain events, never dropped.

**Actions.** Implement only what the agent really supports. A method you don't override means the ability isn't there, and the UI hides its control.

| Method | Called when | Return |
|---|---|---|
| `send(sid, text, images)` | The user replies | A short status string, or `{"message", "ui": [...]}` for UI actions |
| `key(sid, key)` | The user taps an approval option, or interrupts (`esc`) | A short status string |
| `answer(sid, answers)` | The user answers a multiple-choice question | A short status string |
| `close(sid)` | The user closes the session | A short status string |
| `history`, `pump`, `items` | Only for agents without transcript files | Items |
| `start()`, `disable()` | The plugin is enabled or turned off; `disable` must remove anything it installed | — |

Raise an exception with a clear message when something can't be done. The host shows it to the user, and repeated failures disable the plugin automatically without affecting other agents.

## Develop and test locally

1. **Start from an existing plugin.** Copy [`plugins/qwen-code`](../plugins/qwen-code) to `plugins/<your-id>`, rename the `id`, and adapt `sessions()` and the normalizer.
2. **Check it without running Kiteline.** This loads the plugin exactly like the watcher does, validates the manifest and prints `detect()` and the sessions found on this computer. It is read-only and never calls `start()`.
   ```bash
   python3 tools/plugin_check.py plugins/<your-id>
   python3 tools/plugin_check.py plugins/<your-id> --json   # full snapshots
   ```
3. **Try it in the app.** Copy the folder to `~/.ccpulse/plugins/<your-id>/` (Windows: `%USERPROFILE%\.ccpulse\plugins\<your-id>\`) and restart Kiteline. It appears in Settings → Plugins with its abilities and any load errors, and its sessions appear on your phone. Plugins in this folder are loaded as they are. Plugins downloaded from the official index are signature-checked, so only put code you trust here.
4. **Test every ability you claim** on each platform and form you mark as `verified`. Leave `verified` false for anything you haven't run yourself.

## Contribute your plugin

1. Open a pull request that adds `plugins/<id>/`: `plugin.json`, `plugin.py`, any `assets/`, and a short `README.md` saying what you tested and how.
2. We review the code against the rules below, test it, then **sign it and publish it to the official plugin index**. Every Kiteline user gets it automatically, with no app update. [PLUGINS.md](../PLUGINS.md) updates with the next sync.
3. Contributions follow [CONTRIBUTING.md](../CONTRIBUTING.md).

### Rules every plugin must follow

- **No credentials.** Never read, store or forward AI login data, API keys or session tokens, and never call model APIs. `secret.read` is only for an agent's local secret, and only as an opt-in.
- **Don't modify the agent.** Use the interfaces it offers. Anything installed into the agent goes through the host, is marked, and is removed on `disable()`.
- **Local only.** Talk only to the agent's local interfaces (local sockets, `127.0.0.1`). No other network access.
- **Prefer reading.** If a public interface exists, don't simulate input. If there's no safe way to act, stay view-only and say why in `read_only`.
- **Standard library only.** The watcher runs on remote servers where nothing can be installed.
- **Bilingual text.** Anything the user sees comes in Chinese, with an English version in the matching `…En` field.
- **Be quick and quiet.** `detect()` and `sessions()` run often. Keep them fast, don't block, and don't print to stdout (the watcher speaks JSON Lines on stdout).
