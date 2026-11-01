// Kiteline 的 Cursor 配套扩展：手机上对 Cursor 编辑器里的对话点「允许 / 拒绝 / 中断」、发消息时，由它在 Cursor 里执行。
// 只调 Cursor 自己注册的命令（系统通知上的「允许 / 拒绝」按钮用的就是这两条），按对话 id 操作，不碰键盘、不抢前台：
//   composer.acceptPendingFromNotification / composer.rejectPendingFromNotification / composer.cancelChat / composer.openComposer
// 发消息（send）：打开这个对话、聚焦它的输入框、经剪贴板粘贴进去（剪贴板用完还原）。Cursor 没有「提交」的命令，
// 回车由电脑端的 Kiteline 把这个窗口切到前台后按（插件回给电脑端的动作单，见 plugin.py 的 send）。
// Cursor 的 Agents 窗口不加载扩展：那里的对话这里做不了，插件会提示用户切到编辑器窗口。
// 和 watcher 走文件信箱（三个系统一样，不开端口）：目录在同目录的 kiteline.json 里，插件安装时写好。
//   req-<编号>.json  watcher 放进来的请求 {id, cmd, composerId, pids?, ts}；pids 是心跳里开着这个对话的窗口（本扩展进程），
//                    不在里面的窗口不管；没给 pids 时每个窗口都执行一遍（对话不在本窗口时 Cursor 的命令什么也不做）；20 秒前的不管
//   ack-<编号>-<本进程>.json  做完的回执 {ok, error}
//   win-<本进程>.json  每 5 秒一次：本窗口还在、开着哪些对话、打开的项目目录
'use strict';
const vscode = require('vscode');
const fs = require('fs');
const path = require('path');

const COMMANDS = {
  approve: 'composer.acceptPendingFromNotification',
  reject: 'composer.rejectPendingFromNotification',
  cancel: 'composer.cancelChat',
  open: 'composer.openComposer',
  send: null,   // 见 sendText
};
let timers = [];
let dir = null;

function writeJson(file, data) {
  const tmp = file + '.' + process.pid + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(data));
  fs.renameSync(tmp, file);
}

async function openIds() {
  try {
    const ids = await vscode.commands.executeCommand('composer.getOrderedSelectedComposerIds');
    return Array.isArray(ids) ? ids.filter((id) => typeof id === 'string') : [];
  } catch (e) {
    return [];
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function folders() {
  return (vscode.workspace.workspaceFolders || []).filter((f) => f.uri.scheme === 'file').map((f) => f.uri.fsPath);
}

/** 把文字放进这个对话的输入框（不提交）：打开 → 聚焦 → 借剪贴板粘贴，1.5 秒后还原（同 VS Code 配套扩展）。
 *  电脑端先把这个窗口切到前台才叫这一步：Wayland 上后台窗口写不了剪贴板，会粘出剪贴板里的旧内容（11-01 实测） */
async function sendText(composerId, text) {
  await vscode.commands.executeCommand('composer.openComposer', composerId);
  await sleep(350);
  await vscode.commands.executeCommand('composer.focusComposer');
  await sleep(200);
  const saved = await vscode.env.clipboard.readText();
  await vscode.env.clipboard.writeText(text);
  if ((await vscode.env.clipboard.readText()) !== text) {
    await vscode.env.clipboard.writeText(saved);
    throw new Error('clipboard not writable');
  }
  await vscode.commands.executeCommand('editor.action.clipboardPasteAction');
  setTimeout(() => { vscode.env.clipboard.writeText(saved); }, 1500);
  await sleep(250);
}

async function beat() {
  try {
    writeJson(path.join(dir, 'win-' + process.pid + '.json'),
      {pid: process.pid, ts: Date.now(), open: await openIds(), folders: folders(), focused: vscode.window.state.focused,
        version: vscode.version, app: vscode.env.appName});
  } catch (e) { /* 目录被删了：下次再写 */ }
}

const handled = new Set();
async function poll() {
  let names;
  try {
    names = fs.readdirSync(dir);
  } catch (e) {
    return;
  }
  for (const name of names) {
    if (!name.startsWith('req-') || !name.endsWith('.json') || handled.has(name)) continue;
    handled.add(name);
    let req;
    try {
      req = JSON.parse(fs.readFileSync(path.join(dir, name), 'utf8'));
    } catch (e) {
      continue;
    }
    if (!req || Date.now() - (req.ts || 0) > 20000) continue;
    if (Array.isArray(req.pids) && !req.pids.includes(process.pid)) continue;
    const command = COMMANDS[req.cmd];
    const ack = {ok: false, pid: process.pid, ts: Date.now()};
    if (!Object.prototype.hasOwnProperty.call(COMMANDS, req.cmd) || typeof req.composerId !== 'string') {
      ack.error = 'unknown request';
    } else {
      try {
        if (req.cmd === 'send') {
          await sendText(req.composerId, String(req.text || ''));
        } else {
          await vscode.commands.executeCommand(command, req.composerId);
        }
        ack.ok = true;
        ack.open = (await openIds()).includes(req.composerId);
      } catch (e) {
        ack.error = String(e && e.message || e);
      }
    }
    try {
      writeJson(path.join(dir, 'ack-' + req.id + '-' + process.pid + '.json'), ack);
    } catch (e) { /* watcher 会当成没回 */ }
  }
  if (handled.size > 500) handled.clear();
}

function activate(context) {
  try {
    dir = JSON.parse(fs.readFileSync(path.join(__dirname, 'kiteline.json'), 'utf8')).dir;
    fs.mkdirSync(dir, {recursive: true});
  } catch (e) {
    return;
  }
  beat();
  timers.push(setInterval(beat, 5000), setInterval(poll, 400));
  context.subscriptions.push({dispose: deactivate});
}

function deactivate() {
  timers.forEach(clearInterval);
  timers = [];
  if (dir) {
    try { fs.unlinkSync(path.join(dir, 'win-' + process.pid + '.json')); } catch (e) { /* 已经没了 */ }
  }
}

module.exports = {activate, deactivate};
