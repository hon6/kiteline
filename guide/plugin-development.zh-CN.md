# 插件开发指南

[English](plugin-development.md) · **简体中文**

Kiteline 通过**插件**支持新的编程 Agent。插件是一个小小的 Python 模块，告诉 Kiteline 这个 Agent 的会话在哪、怎么读、能做哪些操作。新增一个 Agent，手机、手表和电脑端的界面都不用更新，它们只按统一格式显示。

目前支持哪些 Agent、各自能做到什么，见 [PLUGINS.zh-CN.md](../PLUGINS.zh-CN.md)。本文介绍插件的工作方式、怎么写一个插件，以及怎么把它贡献到本仓库。

## 为什么有的 Agent 只能查看

Kiteline 对所有 Agent 都遵守三条原则：

1. **不碰 AI 凭证**：不登录任何 AI 服务，不读取、不转发 API Key 和会话令牌，也不调用模型接口。
2. **不修改 Agent 本身**：不改它的程序，不注入代码，也不用它没有开放的私有钩子。
3. **只用 Agent 在你电脑上提供的东西。**

在这三条之内，触达一个会话有四种途径，优先级从高到低：

| 途径 | 能做什么 | 例子 |
|---|---|---|
| Agent 自己的本机接口（本机服务、IPC、RPC） | 完整操作：回复、确认、回答、中断 | Codex、OpenCode、DeepSeek Harness |
| Agent 提供的扩展点（编辑器 URI、hooks） | 回复、确认 | Claude Code 的 VS Code 扩展、Cursor 的 hooks |
| 会话所在的终端（tmux 窗格、Windows 控制台） | 回复、确认 | tmux 里的 Claude Code、Qwen Code、Cursor 命令行 |
| Agent 写在磁盘上的会话文件 | **只能查看** | Proma；不在 tmux 里的命令行会话 |

如果一个 Agent 前三种途径都没有提供，Kiteline 仍然能显示它的会话、步骤和完整对话，但不能替你操作。往随便哪个窗口模拟按键，或者去改 Agent 本身，都会违反上面的原则，还可能把内容发错地方。只读的会话会在输入框里写明原因，例如「Qwen Code 不在 tmux 中运行，只能查看」。

有的 Agent 会把一份本机密钥存在电脑上，供它自己的界面使用，但这并不是开放给第三方的接口，比如 DeepSeek Harness。读取这类密钥的插件必须设为**需手动开启**：默认不接入，用户在「设置 → 插件」看过说明、自己打开后才生效。

## 插件在架构里的位置

```text
iPhone · iPad · 手表 · 电脑端界面      只按统一格式显示
            ▲ 快照、对话项、待确认卡片            ▼ 发消息 / 按键 / 回答 / 关闭
Kiteline 电脑端（Mac App 或 Windows/Linux 电脑端 + 会话监听）
            提供能力：文件、进程、本机 socket、tmux、界面动作、可还原的组件安装
            ▲ 统一格式                            ▼ 调用插件
插件（每个 Agent 一个）               知道会话在哪、怎么翻译成统一格式
            ▲▼
Agent 本身（命令行、编辑器扩展、桌面版）
```

插件运行在会话监听脚本（`watcher/kiteline-watch.py`）里，这个脚本在本机和每台 Remote-SSH 主机上运行。插件不画界面，也不直接碰键盘、剪贴板；需要界面操作时，返回一张动作单，由电脑端安全地执行。

## 目录结构

```text
plugins/<id>/
├── plugin.json   清单
├── plugin.py     实现（Python 3，仅标准库）
└── assets/       可选：要装进 Agent 的组件（插件关闭时会删干净）
```

目录名必须和清单里的 `id` 一致。

## 清单（`plugin.json`）

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

| 字段 | 含义 |
|---|---|
| `id`、`name`、`version` | 标识（与目录名相同）、显示名、语义化版本。与内置插件同 `id` 时，版本更高才会顶替内置的。 |
| `summary`、`summaryEn` | 插件页上的一句话介绍，中英文各一份。 |
| `needs` | 用到的电脑端能力（见下表）。电脑端缺哪项就不加载，并提示用户更新 Kiteline。 |
| `detect` | 插件还没加载时，怎么判断这台电脑装没装这个 Agent：列出的路径或命令任一存在即可。 |
| `support` | 各平台（`mac`、`windows`、`linux`）、各形态（`cli`、`vscode`、`desktop`）能做到什么：能力取自 `view`、`reply`、`approve`、`answer`、`interrupt`；`verified` 表示**你亲自实测过**；`note` 是可选说明。[插件清单](../PLUGINS.zh-CN.md)就是按它生成的。 |
| `caps` | 查看、回复、确认、中断以外的控件：`mode`、`model`、`compact`、`subagents`、`tests`、`close`。 |
| `mark`、`speaker` | 单色标志（24×24 画布的 SVG 路径，`[{"d": "M…", "opacity": 1}]`），以及对话里的称呼（「Qwen 想使用 Bash」）。 |
| `minApp` | 各端最低版本：`mac`、`desktop`、`ios`。只在依赖了较新的能力时才写。 |
| `optIn`、`optInEn` | 用到了 Agent 没有开放给第三方的东西（比如 `secret.read`）时必填：用户打开前看到的说明。 |

### 电脑端能力（`needs`）

| 能力 | 提供什么 |
|---|---|
| `locate` | Agent 装在哪、什么版本 |
| `fs.read`、`fs.tail` | 读文件和目录；跟踪追加写的对话记录文件（偏移、截断） |
| `db.read` | 只读打开 SQLite 数据库 |
| `proc`、`proc.pipe` | 列进程、判断存活、父进程链；经标准输入输出运行子进程 |
| `net.connect`、`net.ws`、`net.http`、`net.sse` | 本机 Unix socket、命名管道、TCP，WebSocket、HTTP、事件流（仅限本机） |
| `term.tmux` | 往会话所在的 tmux 窗格发送文字和按键 |
| `install.file` | 往 Agent 里装带标记的组件，插件关闭时删除 |
| `secret.read` | 读取 Agent 存在本机的密钥（只能用于需手动开启的插件） |
| `ui.keys` | 返回界面动作单（切到窗口、再按键），电脑端每一步都先核对前台 |

完整规范见 [agent-plugins.md](agent-plugins.md)。

## 实现（`plugin.py`）

`plugin.py` 导出 `create(kl)`，返回一个 `kl.AgentPlugin` 的实例。`kl` 就是会话监听脚本本身，提供基类和常用工具，比如 `kl.HOME`、`kl.read_text`、`kl.pid_alive`、`kl.parse_ts`、`kl.clip`、`kl.find_tmux_pane`、`kl.tmux_send`、`kl.tool_brief`。

下面是一个最小的只读插件。假设这个 Agent 给每个运行中的会话写一个 JSON 文件，对话记录写成 JSONL：

```python
import glob, json, os


def create(kl):
    ROOT = os.path.join(kl.HOME, ".acme")

    def acme_normalize(offset, entry):
        """对话记录的一行 → 对话项（t：user / text / thinking / tool / result）"""
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
        read_only = "Acme 没有开放远程操作的接口，只能查看"
        normalize = staticmethod(acme_normalize)   # 类体里读不到外层的同名变量，所以外层函数换个名字

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

**快照**：每个会话是一个字典。必填字段：

- `sessionId`、`agent`、`title`、`cwd`；
- `activity`：`busy`、`idle` 或 `waiting`。

常用可选字段：
- `transcriptPath`：给了它，跟踪文件、翻历史、搜索、取图都由电脑端负责；
- `message`：最新回复预览；
- `pendingTool` / `pendingOptions`：待确认卡片；
- `readOnly`，以及 `readOnlyReason` / `readOnlyReasonEn`：只读时显示的原因。

**对话项**：`normalize(offset, entry)` 把对话记录的一行转成对话项：
- `user`、`text`、`thinking` 带 `text`；
- `tool` 带 `name`、`brief`、`input`、`toolId`；
- `result` 带 `toolId`、`text`、`isError`。

把 Agent 自己的工具名映射成通用名字（`Bash`、`Read`、`Edit`、`Write`、`Grep`、`TodoWrite`……），改动对比和任务清单才能画出来。不认识的对话项类型会按普通提示显示，不会丢。

**操作**：只实现 Agent 真正支持的。没有覆盖的方法 = 没有这项能力，界面上对应的控件不会出现。

| 方法 | 什么时候调用 | 返回 |
|---|---|---|
| `send(sid, text, images)` | 用户回复 | 一句状态，或 `{"message", "ui": [...]}` 界面动作单 |
| `key(sid, key)` | 用户点了确认选项，或中断（`esc`） | 一句状态 |
| `answer(sid, answers)` | 用户回答选择题 | 一句状态 |
| `close(sid)` | 用户关闭会话 | 一句状态 |
| `history`、`pump`、`items` | 只有没有对话记录文件的 Agent 才需要 | 对话项 |
| `start()`、`disable()` | 插件启用、被关闭时；`disable` 要删掉自己装进去的东西 | — |

做不到的时候抛出带清楚说明的异常，电脑端会显示给用户。连续出错的插件会被自动停用，不影响其他 Agent。

## 本机开发与测试

1. **从现成的插件开始**：把 [`plugins/qwen-code`](../plugins/qwen-code) 复制成 `plugins/<你的 id>`，改掉 `id`，再改 `sessions()` 和对话记录的转换。
2. **不开 Kiteline 先检查**：下面的命令按会话监听脚本的规则加载插件、核对清单，打印 `detect()` 结果和这台电脑上找到的会话。它是只读的，不会调用 `start()`。
   ```bash
   python3 tools/plugin_check.py plugins/<你的 id>
   python3 tools/plugin_check.py plugins/<你的 id> --json   # 输出完整快照
   ```
3. **在 App 里试用**：把目录复制到 `~/.ccpulse/plugins/<你的 id>/`（Windows：`%USERPROFILE%\.ccpulse\plugins\<你的 id>\`），重启 Kiteline。它会出现在「设置 → 插件」里，显示能力和加载错误；它的会话也会出现在手机上。这个目录里的插件会被原样加载（从官方索引下载的插件才做签名校验），所以只放你信得过的代码。
4. **逐项实测你声明的能力**：标成 `verified` 的平台和形态都要亲自跑过；没跑过的保持 `false`。

## 贡献你的插件

1. 提交一个 Pull Request，新增 `plugins/<id>/`：`plugin.json`、`plugin.py`、需要的 `assets/`，再加一份简短的 `README.md`，写清你测了什么、怎么测的。
2. 我们按下面的规则审核代码、实测，然后**签名并发布到官方插件索引**。所有 Kiteline 用户会自动获得这个插件，不需要更新 App；[插件清单](../PLUGINS.zh-CN.md)会在下次同步时更新。
3. 贡献需遵守 [CONTRIBUTING.md](../CONTRIBUTING.md)。

### 每个插件都必须遵守的规则

- **不碰凭证**：不读取、不存储、不转发 AI 登录信息、API Key 和会话令牌，也不调用模型接口。`secret.read` 只用于 Agent 存在本机的密钥，而且必须设为需手动开启。
- **不修改 Agent**：只用它提供的接口。装进 Agent 的东西一律经电脑端安装、带标记，并在 `disable()` 时删除。
- **只在本机通信**：只连 Agent 的本机接口（本机 socket、`127.0.0.1`），不做其他网络访问。
- **能读就不操作**：有公开接口就不模拟输入；没有安全的操作方式时保持只读，并在 `read_only` 里说明原因。
- **仅用标准库**：会话监听要在远端服务器上运行，那里不能装依赖。
- **中英双语**：用户能看到的文字写中文，英文版放在对应的 `…En` 字段里。
- **快、安静**：`detect()` 和 `sessions()` 会被频繁调用，要快、不能阻塞，也不要往标准输出打印（会话监听用标准输出传 JSON Lines）。
