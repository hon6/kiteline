// Kiteline 配套扩展：每个 VS Code 窗口在本机开一个只有当前用户能连的通道（Unix 套接字，权限 600），
// Kiteline 电脑端经它切到指定的 Claude Code 会话、核对窗口在前台且当前标签就是这个会话、把输入框聚焦、粘贴文字。
// 最后的回车由 Kiteline 用虚拟键盘按（VS Code 的接口没法往别的扩展的网页视图里按键）。
// 为什么需要：Wayland 桌面（Ubuntu、Fedora 默认）不许普通程序找窗口、切窗口、读窗口标题，以前的 xdotool 办法用不了
"use strict";
const vscode = require("vscode");
const net = require("net");
const fs = require("fs");
const os = require("os");
const path = require("path");

const MAX_REQUEST = 1024 * 1024;   // 一条请求最多 1 MB
const MAX_TEXT = 200000;           // 粘贴的文字最多 20 万字
// 会话 id 是 Claude Code 记录文件名（UUID）：别的格式一律不认
const SESSION_ID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

function socketDir() {
  if (process.platform === "win32") return null;   // Windows 仍用原来的窗口模拟办法
  // 首选 $XDG_RUNTIME_DIR（每个用户一份、只有自己进得去）；没有时退到临时目录下按用户分开的 kiteline-<uid>
  if (process.env.XDG_RUNTIME_DIR) return path.join(process.env.XDG_RUNTIME_DIR, "kiteline");
  return path.join(os.tmpdir(), "kiteline-" + process.getuid());
}

// 目录要是自己的：是目录、不是符号链接、属主是自己，权限收成 700。别的用户抢先在公共临时目录里建好的不能用（不开通道）
function ownDir(dir) {
  try { fs.mkdirSync(dir, { mode: 0o700 }); } catch (error) { if (error.code !== "EEXIST") return false; }
  try {
    const info = fs.lstatSync(dir);
    if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid()) return false;
    if ((info.mode & 0o777) !== 0o700) fs.chmodSync(dir, 0o700);
    return true;
  } catch (_) {
    return false;
  }
}

function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }

function state() {
  const group = vscode.window.tabGroups.activeTabGroup;
  const tab = group && group.activeTab;
  const input = tab && tab.input;
  return {
    ok: true,
    version: 1,
    focused: vscode.window.state.focused,
    folders: (vscode.workspace.workspaceFolders || []).map((f) => f.uri.fsPath),
    remote: vscode.env.remoteName || null,
    activeTab: tab ? tab.label : null,
    activeKind: input && input.viewType ? String(input.viewType) : null,
  };
}

// 只认这几个固定动作（同一用户下别的程序也连得上这个套接字，不留「执行任意命令」的口子）
async function handle(request) {
  switch (request && request.cmd) {
    case "state":
      return state();
    case "open": {
      // 和扩展自己的链接 vscode://anthropic.claude-code/open?session=&prompt= 同一个命令，但不弹「允许打开链接吗」。
      // 不带 session = 新开会话；prompt 只预填进新开的面板（扩展本身如此，会话已经开着时不填）
      const session = request.session ? String(request.session) : undefined;
      if (session !== undefined && !SESSION_ID.test(session)) return { ok: false, error: "invalid session id" };
      const prompt = request.prompt ? String(request.prompt) : undefined;
      if (prompt !== undefined && prompt.length > MAX_TEXT) return { ok: false, error: "prompt too long" };
      // 远端（Remote-SSH）窗口里 Claude Code 跑在远端的扩展宿主，跨宿主调命令时参数里的 undefined 会变成 null，
      // 扩展拿 null 当会话 id 会出错（10-23 实测）：远端窗口里不指定会话就传空字符串（扩展把空字符串当成没有会话）
      const args = vscode.env.remoteName ? [session || "", prompt || ""] : [session, prompt];
      await vscode.commands.executeCommand("claude-vscode.primaryEditor.open", ...args);
      await sleep(700);
      return state();
    }
    case "focus":
      await vscode.commands.executeCommand("claude-vscode.focus");
      await sleep(250);
      return state();
    case "paste": {
      // 借系统剪贴板中转、1.5 秒后还原（同 Mac 版）：装了剪贴板历史工具的，历史里会留下这条消息
      const text = String(request.text || "");
      if (!text || text.length > MAX_TEXT) return { ok: false, error: "text empty or too long" };
      const saved = await vscode.env.clipboard.readText();
      await vscode.env.clipboard.writeText(text);
      await vscode.commands.executeCommand("editor.action.clipboardPasteAction");
      setTimeout(() => { vscode.env.clipboard.writeText(saved); }, 1500);
      await sleep(250);
      return state();
    }
    case "reload":
      // 手机上点「尝试重连」：远端窗口里「工作区不存在」这类关掉对话框后，重新加载这个窗口（Mac / Windows 版用命令面板做同一件事）。
      // 先回话再重载：重载会连扩展宿主一起重启，通道跟着断
      setTimeout(() => { vscode.commands.executeCommand("workbench.action.reloadWindow"); }, 100);
      return { ok: true };
    default:
      return { ok: false, error: "unknown command" };
  }
}

function activate(context) {
  const dir = socketDir();
  if (!dir || !ownDir(dir)) return;
  const file = path.join(dir, "vscode-" + process.pid + ".sock");
  try { fs.unlinkSync(file); } catch (_) { /* 没有旧的 */ }
  const server = net.createServer((socket) => {
    let buffer = "";
    socket.setEncoding("utf8");
    socket.on("error", () => {});
    socket.on("data", async (chunk) => {
      buffer += chunk;
      if (buffer.length > MAX_REQUEST) { socket.destroy(); return; }
      let index;
      while ((index = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, index);
        buffer = buffer.slice(index + 1);
        let reply;
        try { reply = await handle(JSON.parse(line)); } catch (error) { reply = { ok: false, error: String((error && error.message) || error) }; }
        socket.write(JSON.stringify(reply) + "\n");
      }
    });
  });
  // 目录已经是 700，别人进不来；套接字再收成 600。不改 umask：它是整个扩展宿主进程共用的，会连带别的扩展
  server.listen(file, () => {
    try { fs.chmodSync(file, 0o600); } catch (_) { /* 刚建好的，改不了也有目录挡着 */ }
  });
  server.on("error", () => {});
  context.subscriptions.push({ dispose() { server.close(); try { fs.unlinkSync(file); } catch (_) { /* 已删 */ } } });
}

function deactivate() {}

module.exports = { activate, deactivate };
