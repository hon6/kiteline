// 数据流大屏底部的四块仪表：思考流、工具通道、模型核心（点组成的球，一个会话一条纬度带）、检查矩阵（一行一个会话的等距方块）。
// 每帧都画、按时间滚动（11-02：要灵敏、变化大，不能几乎不动）：每次调用在四块上都有明显反应——
// 波形冒尖、热度格闪、那条工具通道亮起再退、球上炸开一圈光点、新的检查结果从下往上长出来；数字滚动变化。

import { t, lang } from './i18n.js';
import { cacheRatio } from './flowdata.js';

const MONO = '"JetBrains Mono", ui-monospace, "SF Mono", Menlo, Consolas, monospace';
const SANS = '-apple-system, "PingFang SC", "Microsoft YaHei UI", "Noto Sans CJK SC", sans-serif';
export const KIND_COLOR = {
  read: '#6ea8ff', grep: '#6ea8ff', web: '#5fe0c8', search: '#5fe0c8', edit: '#f2cf5b', write: '#f2cf5b', test: '#8be37c', build: '#8be37c',
  run: '#9aa1b2', git: '#f0a35e', ssh: '#9b8cff', report: '#9b8cff', msg: '#ff5fa8', agent: '#ff5fa8', user: '#e6e8ef', ask: '#f0a35e', skill: '#9aa1b2',
};
export const kindColor = (ev) => ev.err ? '#ff5a6a' : KIND_COLOR[ev.k] || '#9aa1b2';
export const VERB = { read: '读', grep: '搜', web: '网页', search: '搜网页', edit: '改', write: '写', run: '命令', build: '构建', test: '测试', git: 'Git', ssh: '远程', report: '汇报', msg: '发消息', agent: '子 agent', ask: '问你', skill: '技能', user: '你说' };

export function fmtTok(n) {
  if (!n) return '0';
  if (lang === 'en') {
    if (n >= 1e9) return (n / 1e9).toFixed(1) + 'B';
    if (n >= 1e6) return (n / 1e6).toFixed(1) + 'M';
    if (n >= 1000) return (n / 1000).toFixed(n >= 1e5 ? 0 : 1) + 'k';
    return String(Math.round(n));
  }
  if (n >= 1e8) return (n / 1e8).toFixed(1) + '\u4ebf';   // 亿（写成转义：只在中文下用，不进翻译清单）
  if (n >= 1e4) return (n / 1e4).toFixed(n >= 1e5 ? 0 : 1) + '\u4e07';   // 万
  if (n >= 1000) return (n / 1000).toFixed(1) + 'k';
  return String(Math.round(n));
}
function fit(g, s, w) { s = String(s || ''); if (g.measureText(s).width <= w) return s; while (s.length > 1 && g.measureText(s + '…').width > w) s = s.slice(0, -1); return s + '…'; }
export const sayOf = (ev) => ev.k === 'user' ? ev.label : `${t(VERB[ev.k] || '命令')} ${ev.w[0] ? ev.w[0].split('/').pop() : ev.r[0] ? ev.r[0].split('/').pop() : ev.label}`;
const rgba = (hex, a) => { const n = parseInt(hex.slice(1), 16); return `rgba(${n >> 16},${(n >> 8) & 255},${n & 255},${a})`; };

const LANES = [['读', ['read']], ['搜', ['grep']], ['网页', ['web', 'search']], ['改', ['edit']], ['写', ['write']], ['命令', ['run', 'skill']], ['测试', ['test']], ['构建', ['build']], ['Git', ['git']], ['远程', ['ssh']], ['汇报', ['report']], ['消息', ['msg', 'agent']]];
const WAVE_MS = 90000;    // 思考流波形：屏宽 = 最近一分半
const HIST_N = 60;        // 工具通道直方图：最近 60 秒，一秒一格

export class Dash {
  constructor(data) {
    this.data = data;
    this.P = {};
    for (const id of ['thought', 'lanes', 'core', 'matrix']) {
      const c = document.getElementById('fd-' + id);
      this.P[id] = { c, g: c.getContext('2d'), w: 0, h: 0 };
    }
    this.live = [];                 // 实时来的调用 {at, ev}（波形、直方图按时间画；补的历史不算）
    this.laneHit = new Array(LANES.length).fill(-1e9);
    this.pulse = new Map();         // 会话 key -> 球上那条带亮多少
    this.sparks = [];               // 球上炸开的光点
    this.checkAt = new Map();       // 检查结果 -> 出现的时刻（长出来的动画）
    this.shown = {};                // 滚动中的数字
    this.codeAt = 0;
    this.sphere = [...Array(720)].map((_, i) => { const y = 1 - (i + .5) / 720 * 2, r = Math.sqrt(1 - y * y), a = i * 2.39996; return [Math.cos(a) * r, y, Math.sin(a) * r]; });
    this.frame = 0;
  }

  resize() {
    const dpr = Math.min(2, devicePixelRatio || 1);
    for (const p of Object.values(this.P)) {
      p.w = p.c.clientWidth; p.h = p.c.clientHeight;
      p.c.width = Math.max(1, p.w * dpr); p.c.height = Math.max(1, p.h * dpr); p.g.setTransform(dpr, 0, 0, dpr, 0, 0);
    }
  }

  event(ev) {
    const now = performance.now();
    this.live.push({ at: now, ev });
    while (this.live.length && now - this.live[0].at > WAVE_MS + 2000) this.live.shift();
    const li = LANES.findIndex(([, ks]) => ks.includes(ev.k));
    if (li >= 0) this.laneHit[li] = now;
    this.pulse.set(ev.key, 1);
    // 球上炸开一圈光点（从这个会话那条带往外飞）
    const band = Math.max(0, this.data.order.indexOf(ev.key)), n = Math.max(1, this.data.order.length);
    const y = 1 - (band + .5) / n * 2, col = kindColor(ev);
    for (let i = 0; i < 18; i++) this.sparks.push({ at: now, y, a: Math.random() * Math.PI * 2, v: .5 + Math.random() * .9, col });
    if (this.sparks.length > 400) this.sparks.splice(0, this.sparks.length - 400);
    if (ev.k === 'edit' || ev.k === 'write') this.codeAt = now;
  }

  tickSecond() {}
  set dirty(v) {}

  /// 球每帧画，另外三块隔一帧画一次（30 帧也看着顺）
  draw(now) {
    this.frame++;
    this.core(now);
    if (this.frame % 2) return;
    this.thought(now); this.lanes(now); this.matrix(now);
  }

  get rate() { let n = 0; for (const s of this.data.sessions.values()) n += this.data.rate(s); return n; }
  get busy() { let n = 0; for (const s of this.data.sessions.values()) if (s.activity === 'busy') n++; return n; }
  shortName(key) { const s = this.data.sessions.get(key); const n = s ? s.title : ''; return n.length > 9 ? n.slice(0, 9) + '…' : n; }
  /// 数字滚动着变过去
  roll(key, target) {
    const cur = this.shown[key] ?? target;
    const next = Math.abs(target - cur) < .5 ? target : cur + (target - cur) * .12;
    this.shown[key] = next;
    return next;
  }

  thought(now) {
    const { g, w, h } = this.P.thought, G = this.data.G;
    if (!w) return;
    g.clearRect(0, 0, w, h);
    const x0 = 46, x1 = w - 64, busy = this.busy;
    // 两条按时间滚动的波形：调用（高 = 结果大小）、思考（高 = 想了几秒）；有会话在工作时基线轻轻起伏
    const wave = (y, hh, pick, col, label, val) => {
      g.font = `10px ${SANS}`; g.fillStyle = '#9aa1b2'; g.textAlign = 'left'; g.fillText(label, 10, y + hh * .6);
      g.font = `10px ${MONO}`; g.textAlign = 'right'; g.fillStyle = col; g.fillText(val, w - 10, y + hh * .6); g.textAlign = 'left';
      const base = y + hh, amp = Math.min(3, busy) * 1.1;
      g.beginPath();
      for (let x = x0; x <= x1; x += 2) {
        const tm = now - (x1 - x) / (x1 - x0) * WAVE_MS;
        g.lineTo(x, base - Math.abs(Math.sin(tm / 420 + y)) * amp * Math.sin(tm / 1300));
      }
      g.strokeStyle = rgba(col, .35); g.lineWidth = 1; g.stroke();
      for (const { at, ev } of this.live) {
        const x = x1 - (now - at) / WAVE_MS * (x1 - x0);
        if (x < x0) continue;
        const v = pick(ev);
        if (!v) continue;
        const a = Math.min(hh, 6 + v * hh), fresh = Math.max(0, 1 - (now - at) / 2500);
        g.strokeStyle = col; g.globalAlpha = .55 + fresh * .45; g.lineWidth = 1.2 + fresh * 1.5;
        g.beginPath(); g.moveTo(x - 4, base); g.lineTo(x - 1.5, base + 2); g.lineTo(x, base - a); g.lineTo(x + 2, base + a * .2); g.lineTo(x + 4, base); g.stroke();
        if (fresh > 0) { g.fillStyle = rgba(col, fresh * .5); g.beginPath(); g.arc(x, base - a, 2 + fresh * 4, 0, 7); g.fill(); }
        g.globalAlpha = 1;
      }
    };
    const lastTh = [...this.live].reverse().find(r => r.ev.th)?.ev;
    wave(4, 22, ev => Math.min(1, .35 + Math.log2(1 + (ev.sz || 400) / 300) / 8), '#ff7fb8', t('调用'), t('%@ 次/分', this.rate));
    wave(34, 22, ev => ev.th ? Math.min(1, ev.th / 20) : 0, '#c6b8ff', t('思考'), lastTh ? t('%@ 秒', lastTh.th.toFixed(1)) : '—');
    // 热度格：最近 160 次调用，最新的一格闪
    g.font = `9.5px ${SANS}`; g.fillStyle = '#5d6476'; g.fillText(t('最近调用热度'), 10, 72);
    const cols = 40, rows = 4, cw = (w - 20) / cols, ch = 9, y0 = 77, cells = G.recent.slice(-cols * rows);
    cells.forEach((r, i) => {
      const age = now - r.at, flash = age < 1800 ? 1 - age / 1800 : 0;
      g.globalAlpha = Math.min(1, .3 + Math.min(.7, Math.log2(1 + (r.ev.sz || 200) / 200) / 6) + flash);
      const x = 10 + (i % cols) * cw, y = y0 + Math.floor(i / cols) * (ch + 2);
      g.fillStyle = kindColor(r.ev); g.fillRect(x, y, cw - 1.5, ch);
      if (flash) { g.fillStyle = `rgba(255,255,255,${flash * .7})`; g.fillRect(x, y, cw - 1.5, ch); }
    });
    g.globalAlpha = 1;
    // 最近几条：新来的那条亮一下、从右边滑进来
    const ty = y0 + rows * (ch + 2) + 14;
    G.recent.slice(-7).reverse().forEach((r, i) => {
      const y = ty + i * 14;
      if (y > h - 4) return;
      const age = now - r.at, slide = i === 0 && age < 400 ? (1 - age / 400) * 30 : 0, glow = i === 0 && age < 2500 ? 1 - age / 2500 : 0;
      if (glow) { g.fillStyle = rgba(kindColor(r.ev), glow * .16); g.fillRect(6, y - 10, w - 12, 13); }
      g.font = `9.5px ${SANS}`; g.fillStyle = '#5d6476'; g.fillText(fit(g, this.shortName(r.key), 76), 10 + slide, y);
      g.fillStyle = kindColor(r.ev); g.fillText(t(VERB[r.ev.k] || '命令'), 92 + slide, y);
      g.font = `9.5px ${MONO}`; g.fillStyle = i ? '#7d8496' : '#e6e8ef';
      g.fillText(fit(g, r.ev.k === 'user' ? r.ev.label : (r.ev.w[0] || r.ev.r[0] || r.ev.label), w - 152), 142 + slide, y);
    });
    document.getElementById('fd-thought-n').textContent = t('%@ 个会话在工作', busy);
  }

  lanes(now) {
    const { g, w, h } = this.P.lanes, G = this.data.G;
    if (!w) return;
    g.clearRect(0, 0, w, h);
    const lw = w * .58, counts = LANES.map(([, ks]) => ks.reduce((a, k) => a + (G.by[k] || 0), 0)), mx = Math.max(1, ...counts);
    // 放不下 12 行（横着的手机上四块挤在右边）：只留调用最多的那几条，顺序不变
    const fits = Math.max(3, Math.floor((h - 46) / 11));
    const keep = new Set(LANES.map((_, i) => i).sort((a, b) => counts[b] - counts[a]).slice(0, fits));
    const shown = LANES.map((l, i) => [l, i]).filter(([, i]) => keep.has(i));
    const rowH = Math.min(15, (h - 46) / shown.length);
    shown.forEach(([[name, ks], i], row) => {
      const y = 8 + row * rowH, n = counts[i], age = now - this.laneHit[i], hot = age < 2500 ? 1 - age / 2500 : 0;
      const col = KIND_COLOR[ks[0]], bw = lw - 84, segs = n ? Math.max(1, Math.round(n / mx * 24)) : 0;
      // 刚被调用的那条通道整条亮起来再慢慢退，一道光从左往右扫过去
      if (hot) { g.fillStyle = rgba(col, hot * .18); g.fillRect(6, y, lw - 8, rowH - 1); }
      g.font = `10px ${SANS}`; g.fillStyle = hot ? '#ffffff' : '#7d8496'; g.textAlign = 'left'; g.fillText(t(name), 10, y + 9);
      for (let k = 0; k < 24; k++) {
        const on = k < segs, head = on && k >= segs - 2;
        g.fillStyle = on ? col : 'rgba(255,255,255,.05)';
        g.globalAlpha = on ? (head ? .7 + hot * .3 : .4 + hot * .45) : 1;
        g.fillRect(48 + k * (bw / 24), y + 2, bw / 24 - 1.5, rowH - 6);
        if (hot && on) {
          const sweep = 1 - Math.min(1, Math.abs(k - (1 - hot) * 30) / 3);
          if (sweep > 0) { g.globalAlpha = sweep * hot; g.fillStyle = '#fff'; g.fillRect(48 + k * (bw / 24), y + 2, bw / 24 - 1.5, rowH - 6); }
        }
      }
      g.globalAlpha = 1; g.font = `${hot ? 600 : 400} 10px ${MONO}`; g.textAlign = 'right'; g.fillStyle = hot ? col : '#e6e8ef';
      g.fillText(Math.round(this.roll('lane' + i, n)), lw - 8, y + 9); g.textAlign = 'left';
    });
    // 右边：每分钟调用数 + 最近 60 秒的直方图（一秒一格，一直往左滚）
    const rx = lw + 10;
    g.font = `700 26px ${MONO}`; g.fillStyle = '#e6e8ef'; g.fillText(String(Math.round(this.roll('rate', this.rate))), rx, 34);
    g.font = `10px ${SANS}`; g.fillStyle = '#7d8496'; g.fillText(t('次调用 / 分钟'), rx, 50);
    const hw = w - rx - 10, hb = h - 40, hh = Math.max(10, hb - 66), bins = new Array(HIST_N + 1).fill(0), frac = (now % 1000) / 1000;
    for (const { at } of this.live) { const k = Math.floor((now - at) / 1000); if (k <= HIST_N) bins[k]++; }
    const hm = Math.max(3, ...bins), bwid = hw / HIST_N;
    for (let k = 0; k <= HIST_N; k++) {
      const x = rx + hw - (k + frac) * bwid, v = bins[k];
      if (x < rx) continue;
      g.fillStyle = 'rgba(255,255,255,.05)'; g.fillRect(x, hb - 2, bwid - 1, 2);
      if (!v) continue;
      const bh = v / hm * hh;
      g.fillStyle = k === 0 ? '#ffd0e6' : k < 3 ? '#ff7fb8' : 'rgba(255,127,184,.55)'; g.fillRect(x, hb - bh, bwid - 1, bh);
    }
    g.font = `10px ${SANS}`; g.fillStyle = '#9aa1b2';
    g.fillText(t('读文件 %@', G.by.read || 0), 10, h - 12);
    g.fillText(t('改动 %@', (G.by.edit || 0) + (G.by.write || 0)), w * .36, h - 12);
    g.fillText(t('测试 %@', (G.by.test || 0) + (G.by.build || 0)), w * .66, h - 12);
    document.getElementById('fd-lanes-n').textContent = t('%@ 条通道', LANES.length);
  }

  core(now) {
    const { g, w, h } = this.P.core, G = this.data.G;
    if (!w) return;
    g.clearRect(0, 0, w, h);
    const keys = this.data.order, n = Math.max(1, keys.length), busy = this.busy;
    const lastAt = this.live.length ? this.live[this.live.length - 1].at : -1e9, recent = now - lastAt < 1500;
    const cx = w / 2, cy = h * .36, R0 = Math.min(w * .19, h * .27), rot = now / (busy ? 2600 : 4200);
    // 光晕：有会话在工作时跟着呼吸，有调用时一下变亮
    const breathe = busy ? .5 + .5 * Math.sin(now / 600) : 0, kick = recent ? 1 - (now - lastAt) / 1500 : 0;
    const halo = g.createRadialGradient(cx, cy, R0 * .2, cx, cy, R0 * 1.6);
    halo.addColorStop(0, `rgba(170,110,255,${.14 + breathe * .12 + kick * .3})`); halo.addColorStop(1, 'rgba(170,110,255,0)');
    g.fillStyle = halo; g.beginPath(); g.arc(cx, cy, R0 * 1.6, 0, 7); g.fill();
    // 每条纬度带 = 一个会话：在工作的轻轻亮着呼吸，刚调用的那条亮一下
    const bands = keys.map((k, i) => {
      const s = this.data.sessions.get(k), p = this.pulse.get(k) || 0;
      const work = s && (s.activity === 'busy' || s.activity === 'waiting') ? .25 + .2 * Math.sin(now / 500 + i) : 0;
      return Math.max(p, work);
    });
    for (const [x, y, z] of this.sphere) {
      const X = x * Math.cos(rot) - z * Math.sin(rot), Z = x * Math.sin(rot) + z * Math.cos(rot);
      const p = bands[Math.min(n - 1, Math.floor((1 - y) / 2 * n))] || 0, depth = (Z + 1) / 2, sz = .6 + depth * 1.2 + p * 1.6;
      g.fillStyle = p > .05 ? `rgba(255,${Math.round(160 - p * 70)},215,${.3 + depth * .5 + p * .4})` : `rgba(${Math.round(150 + depth * 60)},${Math.round(140 + depth * 50)},255,${.12 + depth * .55})`;
      g.fillRect(cx + X * R0 - sz / 2, cy - y * R0 - sz / 2, sz, sz);
    }
    for (const [k, v] of this.pulse) this.pulse.set(k, v * .975);
    // 炸开的光点：从那条带往外飞、慢慢暗下去
    for (let i = this.sparks.length - 1; i >= 0; i--) {
      const sp = this.sparks[i], age = (now - sp.at) / 1400;
      if (age >= 1) { this.sparks.splice(i, 1); continue; }
      const r = R0 * Math.sqrt(Math.max(0, 1 - sp.y * sp.y)), d = 1 + age * sp.v * .9;
      const px = cx + Math.cos(sp.a + rot) * r * d, py = cy - sp.y * R0 * (1 + age * .2) + Math.sin(sp.a + rot) * r * .25 * d;
      g.fillStyle = rgba(sp.col, (1 - age) * .9); g.beginPath(); g.arc(px, py, 1.6 * (1 - age) + .6, 0, 7); g.fill();
    }
    g.textAlign = 'center'; g.font = `600 10px ${MONO}`; g.fillStyle = busy || recent ? '#ffd0f0' : '#7d8496';
    g.fillText(busy || recent ? 'WORKING' : 'IDLE', cx, cy + R0 + 14);
    const sess = [...this.data.sessions.values()];
    const ctx = sess.reduce((a, s) => a + (s.context || 0), 0), cache = cacheRatio(sess), tot = this.data.usage?.totals || {};
    const stat = (x, y, k, v, al) => { g.textAlign = al; g.font = `9.5px ${SANS}`; g.fillStyle = '#5d6476'; g.fillText(k, x, y); g.font = `600 13px ${MONO}`; g.fillStyle = '#e6e8ef'; g.fillText(v, x, y + 15); };
    stat(12, 20, t('每分钟调用'), String(Math.round(this.roll('crate', this.rate))), 'left');
    stat(12, 58, t('在工作'), `${busy}/${sess.length}`, 'left');
    stat(12, 96, t('缓存命中'), cache === null ? '—' : Math.round(cache * 100) + '%', 'left');
    stat(w - 12, 20, t('上下文合计'), fmtTok(this.roll('ctx', ctx)), 'right');
    stat(w - 12, 58, t('今日输出'), fmtTok(this.roll('out', tot.output || 0)), 'right');
    stat(w - 12, 96, t('调用'), String(Math.round(this.roll('calls', G.calls))), 'right');
    g.textAlign = 'left';
    const lc = G.lastCode;
    if (lc && h > 205) {   // 矮的时候（横着的手机）不放代码，免得压到数字
      const y0 = h - 48, all = lc.lines.join('\n'), k = Math.min(all.length, Math.floor((now - this.codeAt) / 14));
      g.font = `9.5px ${SANS}`; g.fillStyle = '#5d6476'; g.fillText(fit(g, `${this.shortName(lc.key)} · ${lc.file}`, w - 20), 10, y0 - 4);
      g.font = `9.5px ${MONO}`;
      const lns = all.slice(0, k).split('\n').slice(-3);
      lns.forEach((ln, i) => { g.fillStyle = '#c6b8ff'; g.fillText(fit(g, ln, w - 20), 10, y0 + 11 + i * 12); });
      // 还在敲：光标闪
      if (k < all.length && Math.floor(now / 400) % 2) g.fillRect(10 + Math.min(w - 30, g.measureText(lns[lns.length - 1] || '').width + 1), y0 + 4 + (lns.length - 1) * 12, 5, 9);
    }
  }

  matrix(now) {
    const { g, w, h } = this.P.matrix, G = this.data.G;
    if (!w) return;
    g.clearRect(0, 0, w, h);
    const all = G.testPass + G.testFail;
    g.textAlign = 'left';
    const narrow = w < 300;
    g.font = `700 ${narrow ? 20 : 28}px ${MONO}`; g.fillStyle = G.testFail ? '#ff8a96' : '#8be37c';
    g.fillText(`${Math.round(this.roll('pass', G.testPass))}/${Math.round(this.roll('all', all))}`, 12, 36);
    g.font = `10px ${SANS}`; g.fillStyle = '#7d8496'; g.fillText(t('测试通过'), 12, 52);
    const last = G.checks[G.checks.length - 1], ok = !last || last.ok;
    g.font = `600 10px ${SANS}`; g.fillStyle = ok ? '#8be37c' : '#ff5a6a'; g.strokeStyle = g.fillStyle;
    const tag = ok ? t('可以合并') : t('有失败'), tw = g.measureText(tag).width + 14;
    g.strokeRect(12.5, 60.5, tw, 16); g.fillText(tag, 19, 72);
    const keys = this.data.order.slice(0, 16), cols = 12, rows = Math.max(1, keys.length);
    const s = Math.min(10, (w - 120) / (cols + rows) * 1.6), ox = w * (narrow ? .7 : .54), oy = 16;
    const iso = (c, r) => [ox + (c - r) * s * .9, oy + (c + r) * s * .52];
    for (let r = 0; r < rows; r++) {
      const list = G.checks.filter(x => x.key === keys[r]).slice(-cols);
      for (let c = 0; c < cols; c++) {
        const it = list[c], [x, y] = iso(c, r);
        if (it && !this.checkAt.has(it)) this.checkAt.set(it, now);
        const grow = it ? Math.min(1, (now - this.checkAt.get(it)) / 700) : 1;
        const hh = (it ? 3 + Math.min(14, Math.log2(1 + it.d) * 3) : 1.5) * (it ? 1 - Math.pow(1 - grow, 3) : 1);
        // 一道光斜着扫过整片方块；新长出来的那块亮一下
        const sweep = Math.pow(Math.max(0, Math.sin(now / 900 - (c + r) * .35)), 12) * .5;
        const top = it ? (it.ok ? '#9cf08a' : '#ff6b7a') : '#1c2030', l = it ? (it.ok ? '#5fae52' : '#b8414f') : '#141724', rr = it ? (it.ok ? '#467f3d' : '#8a2f3a') : '#10121b';
        g.fillStyle = l; g.beginPath(); g.moveTo(x - s * .9, y); g.lineTo(x, y + s * .52); g.lineTo(x, y + s * .52 - hh); g.lineTo(x - s * .9, y - hh); g.fill();
        g.fillStyle = rr; g.beginPath(); g.moveTo(x + s * .9, y); g.lineTo(x, y + s * .52); g.lineTo(x, y + s * .52 - hh); g.lineTo(x + s * .9, y - hh); g.fill();
        g.fillStyle = top; g.beginPath(); g.moveTo(x, y - s * .52 - hh); g.lineTo(x + s * .9, y - hh); g.lineTo(x, y + s * .52 - hh); g.lineTo(x - s * .9, y - hh); g.fill();
        const flash = it && grow < 1 ? 1 - grow : 0;
        if (sweep + flash > .01) { g.fillStyle = `rgba(255,255,255,${Math.min(.8, sweep * (it ? 1 : .35) + flash * .8)})`; g.fill(); }
      }
    }
    const rate = all ? G.testPass / all : 0, rx = 40, ry = h - 44, shownRate = this.roll('prate', rate * 1000) / 1000;
    g.lineWidth = 5; g.strokeStyle = 'rgba(255,255,255,.07)'; g.beginPath(); g.arc(rx, ry, 22, 0, 7); g.stroke();
    g.strokeStyle = '#8be37c'; g.beginPath(); g.arc(rx, ry, 22, -Math.PI / 2, -Math.PI / 2 + shownRate * Math.PI * 2); g.stroke();
    g.font = `600 11px ${MONO}`; g.fillStyle = '#e6e8ef'; g.textAlign = 'center'; g.fillText(all ? Math.round(shownRate * 100) + '%' : '—', rx, ry + 4); g.textAlign = 'left';
    const ds = G.checks.slice(-48), dm = Math.max(2, ...ds.map(x => x.d)), bx = 78, bw = w - bx - 12;
    ds.forEach((x, i) => {
      const grow = Math.min(1, (now - (this.checkAt.get(x) ?? 0)) / 700), bh = Math.max(2, Math.log2(1 + x.d) / Math.log2(1 + dm) * 34) * grow;
      g.fillStyle = x.ok ? 'rgba(139,227,124,.7)' : '#ff5a6a'; g.fillRect(bx + i * bw / 48, h - 20 - bh, bw / 48 - 1, bh);
    });
    g.font = `9.5px ${SANS}`; g.fillStyle = '#5d6476'; g.fillText(t('每次检查用时'), bx, h - 6);
    document.getElementById('fd-matrix-n').textContent = t('%@ 次检查', G.checks.length);
    if (this.checkAt.size > 600) this.checkAt = new Map([...this.checkAt].slice(-300));
  }
}
