# FAQ

[简体中文](faq.zh-CN.md)

### Can this get my Claude or Codex account banned?

Kiteline doesn't sign in to any AI service, doesn't use your subscription's tokens and never calls a model API, so it doesn't change how your agents talk to their providers. Your agents keep running on your computer under your own account, exactly as before.

### Do I need an API key?

No. Your agents keep using their own login.

### Is Kiteline free?

The desktop app is free and open source. On the phone, everything is free when it's on the same Wi-Fi as your computer. Only remote access from another network needs Kiteline Pro. See [Remote access](remote-access.md).

### Does my code go through your servers?

Not on the same network. From another network, Kiteline tries a direct peer-to-peer connection first and only uses the relay when that fails; everything is end-to-end encrypted and the relay can't read it.

### Do I have to change how I work?

No. Keep starting sessions in VS Code or the terminal. Terminal sessions need to run inside tmux to accept replies from the phone.

### Does my computer need to stay on?

Yes. Your agents run on your computer, so keep it on and online; turn off automatic sleep.

### Is there an Android or web app?

Not yet. The phone apps are iPhone, iPad and Apple Watch.

### Can several phones connect to one computer?

Yes. Each phone pairs on its own and can be removed on its own.

### Can one phone follow several computers?

Yes. Every session from every paired computer appears in one list, grouped by project, agent or computer.

### Can I use it with agents on a server?

Yes. Install Kiteline on the server with `--service` (see [Install](install.md)), or open the project over VS Code Remote-SSH and Kiteline follows the host through SSH.

### How is this different from Claude Code's Remote Control?

Remote Control continues one Claude Code session in the Claude app. Kiteline shows every agent on every computer in one list, with lock-screen and Apple Watch approvals, screenshots and test reports from the agent, to-dos, goals, group chats between sessions, a code editor with Git and a terminal.

### Is it open source?

The desktop app for Mac, Windows and Linux, the session watcher and the agent plugins are open source under AGPL-3.0 in [this repository](https://github.com/hon6/kiteline). The remote access component, the iPhone, iPad and Apple Watch app shells and the servers are not.
