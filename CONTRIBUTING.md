# Contributing to Kiteline

Thanks for your interest! [中文说明在下面](#参与贡献)。

## Issues and discussions

Bug reports, feature ideas and questions are all welcome. For bugs, please include:

- Your platform and version (Mac app version, or Windows/Linux desktop version, plus the iPhone app version).
- Which agent was involved: Claude Code, Codex, Cursor and so on.
- Steps to reproduce.

Please don't include conversation contents, code or logs you consider private. Security issues: email hon6@foxmail.com instead of opening a public issue.

## Plugins for new agents

Plugins are the easiest way to contribute. Follow the [plugin development guide](docs/plugin-development.md), test your plugin with `python3 tools/plugin_check.py plugins/<id>` and on the platforms you mark as verified, and add a short `plugins/<id>/README.md` describing what you tested. Accepted plugins are signed and published to the official plugin index, so every Kiteline user gets them without an app update, and they're listed in [PLUGINS.md](PLUGINS.md).

## Pull requests

Kiteline is developed in a private repository and synced here, so pull requests are applied by hand rather than merged directly. Small, focused changes are easiest to take in.

The official builds combine this code with components that are not open source (remote access) and ship through the App Store. To keep that possible, **by submitting a pull request you agree that:**

1. your contribution is your own work, or you otherwise have the right to submit it;
2. it is licensed to the project under the AGPL-3.0, **and** you grant hon6 a perpetual, worldwide, royalty-free, irrevocable license to use, modify, sublicense and distribute it under other terms, including in closed-source builds.

You keep the copyright to your contribution. If you can't agree to this, please open an issue describing the change instead.

---

## 参与贡献

### Issue 和讨论

欢迎报 bug、提想法、提问题。报 bug 时请写上：

- 用的是哪个平台和版本：Mac 端版本，或 Windows、Linux 电脑端版本，再加上 iPhone App 版本。
- 涉及哪个 Agent：Claude Code、Codex、Cursor 等。
- 复现步骤。

对话内容、代码、你觉得私密的日志请不要贴。安全问题请发邮件到 hon6@foxmail.com，不要公开提 Issue。

### 为新的 Agent 开发插件

插件是最容易上手的贡献方式。按[插件开发指南](docs/plugin-development.zh-CN.md)开发，用 `python3 tools/plugin_check.py plugins/<id>` 检查，并在你标为已实测的平台上亲自跑通，再加一份简短的 `plugins/<id>/README.md` 写明测了什么。通过审核的插件由我们签名、发布到官方插件索引，所有 Kiteline 用户无需更新 App 即可使用，并列入[插件清单](PLUGINS.zh-CN.md)。

### Pull Request

Kiteline 在私有仓库里开发、同步到这里，所以 PR 会手动合入，而不是直接合并。小而集中的改动最容易收。

官方版本是这些代码加上不开源的组件（远程访问）一起编的，并经 App Store 发布。为了能继续这样做，**提交 PR 即表示你同意：**

1. 贡献是你自己写的，或者你有权提交它；
2. 贡献按 AGPL-3.0 授权给本项目，**同时**授予 hon6 永久、全球、免费、不可撤销的许可，可以按其他条款（包括闭源版本）使用、修改、再授权和分发。

贡献的版权仍归你。不同意的话，请改为提 Issue 描述你想做的改动。
