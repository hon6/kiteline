# Agent plugins

Each folder is one agent plugin: `plugin.json` (manifest) and `plugin.py` (implementation), plus optional `assets/`. Built-in plugins (Codex, OpenCode, DeepSeek Harness, Proma) live inside `watcher/kiteline-watch.py`; the plugins here are distributed separately through the signed plugin index, so they reach users without an app update.

- What each agent supports: [PLUGINS.md](../PLUGINS.md)
- How to write one: [plugin development guide](../guide/plugin-development.md)
- Check a plugin locally: `python3 tools/plugin_check.py plugins/<id>`

Pull requests with new plugins are welcome. We review and test them, then sign and publish them to the official index.

---

# Agent 插件

每个目录是一个 Agent 插件：`plugin.json`（清单）和 `plugin.py`（实现），可选 `assets/`。内置插件（Codex、OpenCode、DeepSeek Harness、Proma）写在 `watcher/kiteline-watch.py` 里；这里的插件经签名的插件索引单独下发，不用更新 App 就能送到用户手上。

- 各 Agent 支持情况：[插件清单](../PLUGINS.zh-CN.md)
- 怎么写插件：[插件开发指南](../guide/plugin-development.zh-CN.md)
- 本机检查插件：`python3 tools/plugin_check.py plugins/<id>`

欢迎提交新插件的 Pull Request，我们审核、实测后签名，发布到官方索引。
