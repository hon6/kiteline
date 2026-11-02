// 数据流大屏的数据：吃和世界一样的东西（/api/state 整份、实时事件 entries、今日用量 usage），
// 把每次工具调用归成「从哪读进来 → 哪个会话 → 做了什么 → 产出去了哪」，再顺手攒全局的统计（卡片上的数字、底部仪表）。

import { t } from './i18n.js';

const BUILD = /\b(xcodebuild|swift build|build\.sh|install\.sh|dotnet (build|publish)|npm run build|pnpm build|yarn build|make\b|cargo build|go build|release\.sh|gradle|vite build)/;
const TEST = /\b(pytest|npm (run )?test|pnpm test|yarn test|run-integration|test_\w+\.py|xcodebuild test|selftest|playwright|jest|vitest|go test|cargo test|unittest)/;
const GIT = /\bgit\s+(commit|push|pull|merge|rebase|checkout|add|switch|tag)\b/;
const SSH = /\bssh\s+(?:-[oiJpFlLR]\s+\S+\s+|-\w+\s+)*([\w.@-]+)/;
const REPORT = /ccpulse-watch\.py\s+(shot|send-image|keyinfo|todo|stage|report)/;
const READ_CMDS = new Set(['cat', 'head', 'tail', 'sed', 'grep', 'rg', 'less', 'wc', 'diff', 'awk', 'jq', 'nl', 'xxd', 'plutil', 'ls', 'find', 'tree', 'stat', 'file']);
const PATHISH = /^(?:~|\.{0,2}\/|[\w.-]+\/)[\w./~@+-]*$|^[\w.-]+\.(?:swift|py|js|ts|tsx|jsx|json|md|cs|sh|html|css|plist|txt|log|yml|yaml|toml|go|rs|java|kt|c|h|cpp|m)$/;
const FAIL = /\b(FAIL(ED)?|failed|error:|Error:|✗|Traceback|BUILD FAILED)\b/;
export const isMemory = (p) => /\/memory\/|CLAUDE\.md|MEMORY\.md/.test(p || '');
export const baseName = (p) => (p || '').replace(/\/$/, '').split('/').pop();

function words(seg) {
  // 粗略按空白切，引号里的整段算一个
  const out = []; let cur = '', q = null;
  for (const ch of seg) {
    if (q) { if (ch === q) q = null; else cur += ch; }
    else if (ch === '"' || ch === "'") q = ch;
    else if (/\s/.test(ch)) { if (cur) out.push(cur), cur = ''; }
    else cur += ch;
  }
  if (cur) out.push(cur);
  return out;
}

/// 一条 shell 命令读了哪些文件、写了哪些文件、连了哪台电脑
function shellFlow(cmd) {
  const r = [], w = [];
  let host = null;
  const m = SSH.exec(cmd); if (m) host = m[1].split('@').pop();
  for (const red of cmd.matchAll(/(?<![0-9&])>{1,2}\s*([^\s;&|<>]+)/g)) if (!red[1].startsWith('/dev/') && PATHISH.test(red[1])) w.push(red[1]);
  for (const seg of cmd.split(/\|\||&&|;|\||\n/)) {
    const ws = words(seg.trim());
    if (!ws.length) continue;
    const head = ws[0].split('/').pop(), args = ws.slice(1).filter(x => !x.startsWith('-'));
    if (READ_CMDS.has(head)) { for (const a of args) if (PATHISH.test(a) && (a.includes('/') || a.includes('.'))) r.push(a); }
    else if (['cp', 'mv', 'tee', 'touch'].includes(head) && args.length) w.push(args[args.length - 1]);
    if (head === 'sed' && ws.includes('-i') && args.length) w.push(args[args.length - 1]);
  }
  return { r, w, host };
}

const lines = (s, n) => String(s || '').split('\n').map(x => x.replace(/\t/g, '  ')).filter(x => x.trim()).slice(0, n);

/// 一条工具调用（entries 里 t = tool 的那条）→ 归好类的一次调用
export function classify(item, cwd) {
  const name = item.name || '';
  const inp = item.input && typeof item.input === 'object' ? item.input : {};
  const lname = name.toLowerCase();
  let k = 'run', r = [], w = [], host = null, label = item.brief || '', code = null;
  const file = inp.file_path || inp.notebook_path || inp.path || '';
  const cmd = typeof inp.command === 'string' ? inp.command : Array.isArray(inp.command) ? inp.command.join(' ') : '';
  if (/^(read|notebookread)$/i.test(name) || lname === 'read_file' || lname === 'view') { k = 'read'; if (file) r.push(file); }
  else if (/^(grep|glob|ls|list)$/i.test(name) || lname.includes('search_files') || lname === 'find') { k = 'grep'; if (file || inp.pattern) r.push(file || ''); label = inp.pattern || label; }
  else if (name === 'WebFetch' || lname.includes('fetch')) { k = 'web'; label = inp.url || label; }
  else if (name === 'WebSearch' || lname.includes('web_search')) { k = 'search'; label = inp.query || label; }
  else if (/^(edit|multiedit|notebookedit)$/i.test(name) || lname.includes('apply_patch') || lname.includes('patch') || lname === 'str_replace') {
    k = 'edit'; if (file) w.push(file);
    const add = inp.new_string ?? (Array.isArray(inp.edits) ? inp.edits.map(e => e.new_string || '').join('\n') : inp.patch || '');
    code = { add: lines(add, 8), del: lines(inp.old_string, 6).length };
  }
  else if (name === 'Write' || lname === 'write_file' || lname === 'create') { k = 'write'; if (file) w.push(file); code = { add: lines(inp.content, 8), del: 0 }; }
  else if (name === 'Task' || name === 'Agent' || lname.includes('subagent')) { k = 'agent'; label = inp.description || label; }
  else if (name === 'SendMessage') { k = 'msg'; label = String(inp.summary || inp.message || label).slice(0, 80); }
  else if (name === 'AskUserQuestion') { k = 'ask'; label = (inp.questions?.[0]?.question) || label; }
  else if (name === 'Skill') { k = 'skill'; label = inp.skill || label; }
  else if (cmd || name === 'Bash' || lname.includes('shell') || lname.includes('exec') || lname === 'bash') {
    const f = shellFlow(cmd); r = f.r; w = f.w; host = f.host;
    k = REPORT.test(cmd) ? 'report' : TEST.test(cmd) ? 'test' : BUILD.test(cmd) ? 'build' : GIT.test(cmd) ? 'git' : host && /[a-z]/i.test(host) ? 'ssh' : 'run';
    label = inp.description || cmd.replace(/^\s*cd\s+\S+\s*&&\s*/, '').split('\n')[0];
    code = { cmd: cmd.replace(/^\s*cd\s+\S+\s*&&\s*/, '').split('\n').slice(0, 3) };
  }
  const rel = (p) => {
    if (!p) return '';
    let s = String(p);
    if (cwd && s.startsWith(cwd.replace(/\/$/, '') + '/')) s = s.slice(cwd.replace(/\/$/, '').length + 1);
    return s.replace(/^\/(Users|home)\/[^/]+\//, '~/');
  };
  const tmp = (p) => /(^|\/)(tmp|scratchpad|private\/var)(\/|$)|^\$|\{/.test(p);
  r = r.map(rel).filter(p => p && !tmp(p));
  w = w.map(rel).filter(p => p && !tmp(p));
  return { k, r, w, host, label: String(label || '').split('\n')[0].slice(0, 120), code, push: /\bgit\s+push\b/.test(cmd), stage: /ccpulse-watch\.py\s+stage/.test(cmd) };
}

export const dirOf = (p) => { const s = (p || '').split('/').filter(Boolean); return s[0] === '~' ? '~' : s.length > 1 ? s[0] : t('（根目录）'); };
const bump = (m, k, n = 1) => m.set(k, (m.get(k) || 0) + n);
export const top = (m, n) => [...m.entries()].sort((a, b) => b[1] - a[1]).slice(0, n);

export class FlowData {
  constructor() {
    this.sessions = new Map();     // key -> 会话（state 里的样子 + 自己攒的）
    this.order = [];               // 中间那列的顺序
    this.pending = new Map();      // toolId -> 调用（等结果回来）
    this.seen = new Set();         // 处理过的条目 id（state 推整份、历史补齐时不重复算）
    this.usage = null;
    this.reset();
  }

  reset() {
    this.G = {
      calls: 0, by: {}, userMsgs: 0, userChars: 0, asks: 0, lastUser: '', memFiles: new Set(), memReads: 0, webFetch: 0, webSearch: 0, lastHost: '',
      cmds: 0, outLines: 0, errs: 0, lastCmd: '', dirsRead: new Map(), filesEdited: new Map(), adds: 0, dels: 0,
      testPass: 0, testFail: 0, builds: 0, buildFail: 0, commits: 0, pushes: 0, thinks: 0, thinkSecs: 0, compacts: 0, readLines: 0,
      lastCode: null, checks: [], recent: [], fanSum: 0, fanN: 0,
    };
  }

  /// /api/state 整份：会话列表、阶段、上下文
  applyState(state) {
    const list = state?.sessions || [];
    const keep = new Set(), initial = !this.loaded;
    this.loaded = true;
    this.added = [];
    for (const raw of list) {
      if (!raw?.key) continue;
      keep.add(raw.key);
      // 打开之后才出现的会话记下出现的时刻：排到前面、卡片亮一下（11-02：新会话加入要看得见）
      if (!this.sessions.has(raw.key) && !initial) this.added.push(raw.key);
      const old = this.sessions.get(raw.key) || { calls: 0, rate: [], lastAt: 0, last: null, thinkingAt: 0, seenAt: initial ? 0 : Date.now() };
      const usage = raw.usage || {};
      Object.assign(old, {
        key: raw.key, title: raw.title || raw.name || t('会话'), cwd: raw.cwd || '', agent: raw.agent || 'claude-code',
        source: raw.sourceName || '', activity: ['busy', 'waiting', 'idle'].includes(raw.activity) ? raw.activity : 'idle',
        failed: !!raw.error, stage: raw.stage && raw.stage.step && raw.stage.total ? raw.stage : null,
        context: usage.context || 0, window: usage.window || 0, model: usage.model || old.model || '',
        cacheRead: usage.cacheRead || 0, cacheWrite: usage.cacheWrite || 0, input: usage.input || 0, output: usage.output || 0,
        activityText: raw.activityText || '', updatedAt: raw.updatedAt || 0, startedAt: raw.startedAt || 0,
      });
      this.sessions.set(raw.key, old);
    }
    for (const k of [...this.sessions.keys()]) if (!keep.has(k)) this.sessions.delete(k);
    // 中间那列：在工作 / 等确认的排前面，其余按最近更新；顺序只在成员变了时重排，免得卡片来回跳
    const sorted = [...this.sessions.values()].sort((a, b) => (rank(b) - rank(a)) || (recency(b) - recency(a)));
    const sig = sorted.map(s => s.key).join('|');
    const changed = sig !== this.sig && (sorted.length !== this.order.length || sorted.some(s => !this.order.includes(s.key)));
    if (changed || !this.order.length) { this.order = sorted.map(s => s.key); }
    else this.order = this.order.filter(k => this.sessions.has(k));
    this.sig = sig;
    return changed;
  }

  /// 一批条目（实时的 entries 或补的历史）→ 一串调用；实时的返回给画面去放动画
  applyEntries(key, items, { live = true } = {}) {
    const s = this.sessions.get(key);
    if (!s || !Array.isArray(items)) return [];
    const out = [];
    for (const it of items) {
      const id = `${key}|${it.id}`;
      if (it.id && this.seen.has(id)) continue;
      if (it.id) { this.seen.add(id); if (this.seen.size > 40000) this.seen = new Set([...this.seen].slice(-20000)); }
      const ts = it.ts ? (it.ts > 1e12 ? it.ts / 1000 : it.ts) : Date.now() / 1000;
      if (it.model) s.model = it.model;
      if (it.t === 'tool') {
        const ev = { ...classify(it, s.cwd), key, ts, err: false, toolId: it.toolId };
        if (s.thinkingAt && ts >= s.thinkingAt) { ev.th = Math.min(120, ts - s.thinkingAt); s.thinkingAt = 0; }
        if (it.toolId) this.pending.set(it.toolId, ev);
        this.account(s, ev, live);
        out.push(ev);
      } else if (it.t === 'result') {
        const ev = this.pending.get(it.toolId);
        if (!ev) continue;
        this.pending.delete(it.toolId);
        const text = String(it.text || '');
        ev.sz = it.fullLength || text.length;
        ev.err = !!it.isError || ((ev.k === 'test' || ev.k === 'build') && FAIL.test(text));
        ev.outLines = text ? text.split('\n').length : 0;
        this.result(s, ev);
      } else if (it.t === 'thinking') {
        s.thinkingAt = ts; this.G.thinks++;
      } else if (it.t === 'user' && it.text && !it.queued) {
        const ev = { k: 'user', key, ts, r: [], w: [], label: String(it.text).split('\n')[0].slice(0, 120), err: false };
        this.account(s, ev, live);
        out.push(ev);
      } else if (it.t === 'event' && /压缩|compact/i.test(String(it.text))) {
        this.G.compacts++;
      }
    }
    if (this.pending.size > 600) this.pending = new Map([...this.pending].slice(-300));
    return out;
  }

  account(s, ev, live) {
    const G = this.G;
    G.calls++; G.by[ev.k] = (G.by[ev.k] || 0) + 1;
    s.calls++; s.last = ev;
    if (live) { s.lastAt = performance.now(); s.rate.push(s.lastAt); }
    if (ev.k === 'user') { G.userMsgs++; G.userChars += ev.label.length; G.lastUser = ev.label; }
    if (ev.k === 'ask') G.asks++;
    for (const p of ev.r) { if (isMemory(p)) { G.memReads++; G.memFiles.add(baseName(p)); } else bump(G.dirsRead, dirOf(p)); }
    if (ev.k === 'web') { G.webFetch++; G.lastHost = (ev.label || '').replace(/^https?:\/\//, '').split('/')[0]; }
    if (ev.k === 'search') { G.webSearch++; G.lastHost = ev.label; }
    if (ev.code?.cmd) { G.cmds++; G.lastCmd = ev.label; }
    if (ev.k === 'edit' || ev.k === 'write') {
      for (const p of ev.w) bump(G.filesEdited, baseName(p));
      G.adds += ev.code?.add?.length || 0; G.dels += ev.code?.del || 0;
      if (ev.code?.add?.length) G.lastCode = { file: baseName(ev.w[0]), lines: ev.code.add.slice(0, 6), key: s.key };
    }
    if (ev.k === 'git') { if (ev.push) G.pushes++; else if (/commit/.test(ev.label)) G.commits++; }
    if (ev.th) G.thinkSecs += ev.th;
    G.recent.push({ key: s.key, ev, at: live ? performance.now() : -1e9 });   // 补的历史不算「刚来」，不闪 if (G.recent.length > 240) G.recent.shift();
  }

  result(s, ev) {
    const G = this.G;
    if (ev.err) G.errs++;
    if (ev.code?.cmd) G.outLines += ev.outLines || 0;
    if (ev.k === 'read' || ev.k === 'grep') G.readLines += ev.outLines || 0;
    if (ev.k === 'test' || ev.k === 'build') {
      if (ev.k === 'test') ev.err ? G.testFail++ : G.testPass++; else { G.builds++; if (ev.err) G.buildFail++; }
      G.checks.push({ key: s.key, ok: !ev.err, d: Math.max(1, (Date.now() / 1000 - ev.ts) || 1), k: ev.k });
      if (G.checks.length > 400) G.checks.shift();
    }
  }

  /// 每分钟调用次数（只算实时来的）
  rate(s) { const now = performance.now(); while (s.rate.length && now - s.rate[0] > 60000) s.rate.shift(); return s.rate.length; }
  live(s) { return s.activity === 'busy' || s.activity === 'waiting' || performance.now() - s.lastAt < 9000; }
}

/// 缓存命中：读缓存占这一轮全部输入的比例（各会话加起来），最多 100%
export function cacheRatio(sessions) {
  let hit = 0, all = 0;
  for (const s of sessions) { hit += s.cacheRead || 0; all += (s.input || 0) + (s.cacheRead || 0) + (s.cacheWrite || 0); }
  return all ? Math.min(1, hit / all) : null;
}

const ms = (v) => (v && v < 1e12 ? v * 1000 : v || 0);
/// 最近动过的时刻：更新、开始、刚出现，取最晚的（新会话没有更新时间也排在前面）
const recency = (s) => Math.max(ms(s.updatedAt), ms(s.startedAt), s.seenAt || 0);
const rank = (s) => (s.activity === 'waiting' ? 3 : s.activity === 'busy' ? 2 : 0) + (s.failed ? 1 : 0);
