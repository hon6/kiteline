// 数据流大屏底部的四块仪表，照用户 11-23 给的参考视频做：思考流、工具通道、模型核心、检查矩阵。
// 每帧都画、按时间往左滚（用户：每个模块都要有交互动画）：
// - 思考流：上面紫线平滑起伏（思考），下面红线一次调用一个方波脉冲；热度格整片往左滚、右边一根亮的扫描线；下面日志逐行往上滚。
// - 工具通道：每次调用是一段彩色横条，从扫描线处出现、往左滑走；下面吞吐直方图往左滚，白色短横标峰值，黄色大数字跳动；底部三个统计带下划条。
// - 模型核心：点阵球转动、中心品红光晕随调用脉动、几颗彩色小星绕着转；下面代码逐字敲出、往上滚、红色光标。
// - 检查矩阵：绿色等距平台，测试在跑时黄色方块冒出来、通过后沉回平台，失败的红方块叠在上面；比分、胶囊标签、环形通过率、紫色用时柱。

import { t, lang } from './i18n.js';
import { cacheRatio } from './flowdata.js';

const MONO = '"JetBrains Mono", ui-monospace, "SF Mono", Menlo, Consolas, monospace';
const SANS = '-apple-system, "PingFang SC", "Microsoft YaHei UI", "Noto Sans CJK SC", sans-serif';
export const KIND_COLOR = {
  read: '#6ea8ff', grep: '#5fd0e8', web: '#5fe0c8', search: '#5fe0c8', edit: '#f2cf5b', write: '#f0a35e', test: '#ff5a7a', build: '#8be37c',
  run: '#9b8cff', git: '#f0a35e', ssh: '#9b8cff', report: '#c6b8ff', msg: '#ff5fa8', agent: '#ff5fa8', user: '#e6e8ef', ask: '#f0a35e', skill: '#9aa1b2',
};
export const kindColor = (ev) => ev.err ? '#ff4d6a' : KIND_COLOR[ev.k] || '#9aa1b2';
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
function fit(g, s, w) { s = String(s || ''); if (w <= 0) return ''; if (g.measureText(s).width <= w) return s; while (s.length > 1 && g.measureText(s + '…').width > w) s = s.slice(0, -1); return s + '…'; }
export const sayOf = (ev) => ev.k === 'user' ? ev.label : `${t(VERB[ev.k] || '命令')} ${ev.w[0] ? ev.w[0].split('/').pop() : ev.r[0] ? ev.r[0].split('/').pop() : ev.label}`;
const rgba = (hex, a) => { const n = parseInt(hex.slice(1), 16); return `rgba(${n >> 16},${(n >> 8) & 255},${n & 255},${a})`; };
const hash = (a, b) => { let h = Math.imul(a * 374761393 + b * 668265263, 1274126177); h ^= h >>> 13; return ((Math.imul(h, 1103515245) >>> 0) % 1000) / 1000; };

const LANES = [['读', ['read']], ['搜', ['grep']], ['网页', ['web', 'search']], ['改', ['edit']], ['写', ['write']], ['命令', ['run', 'skill']], ['测试', ['test']], ['构建', ['build']], ['Git', ['git']], ['远程', ['ssh']], ['汇报', ['report']], ['消息', ['msg', 'agent']]];
const WAVE_MS = 60000;    // 思考流波形：屏宽 = 最近一分钟
const LANE_MS = 40000;    // 工具通道横条：扫描线到左边 = 40 秒
const HEAT_COL_MS = 2000; // 热度格一列 = 2 秒
const HIST_N = 60;        // 吞吐直方图：最近 60 秒，一秒一格
// 热度格的色阶：暗紫 → 紫 → 品红 → 橙 → 黄（参考视频的样子）
const HEAT = ['#1a1030', '#3b1a78', '#7a2bd0', '#d6338f', '#ff6a3d', '#ffd25a'];
const KW = /\b(const|let|var|function|return|if|else|for|while|in|of|await|async|def|class|import|from|export|new|public|private|static|void|bool|int|true|false|None|null|self|this|try|catch|except|with|as|func|struct|guard|elif|lambda|yield)\b/g;

export class Dash {
  constructor(data) {
    this.data = data;
    this.P = {};
    for (const id of ['thought', 'lanes', 'core', 'matrix']) {
      const c = document.getElementById('fd-' + id);
      this.P[id] = { c, g: c.getContext('2d'), w: 0, h: 0 };
    }
    this.live = [];                 // 实时来的调用 {at, ev}（波形、横条、直方图按时间画；补的历史不算）
    this.laneHit = new Array(LANES.length).fill(-1e9);
    this.pulse = new Map();         // 会话 key -> 球上那条带亮多少
    this.sparks = [];               // 球上炸开的光点
    this.checkAt = new Map();       // 检查结果 -> 出现的时刻（方块沉回平台的动画）
    this.shown = {};                // 滚动中的数字
    this.codeAt = 0; this.codeSig = '';
    this.kick = -1e9;               // 最近一次调用（球心光晕、扫描线闪一下）
    this.peak = new Array(HIST_N + 2).fill(0);
    this.sphere = [...Array(260)].map((_, i) => { const y = 1 - (i + .5) / 260 * 2, r = Math.sqrt(1 - y * y), a = i * 2.39996; return [Math.cos(a) * r, y, Math.sin(a) * r]; });
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
    while (this.live.length && now - this.live[0].at > Math.max(WAVE_MS, LANE_MS, HEAT_COL_MS * 64) + 2000) this.live.shift();
    const li = LANES.findIndex(([, ks]) => ks.includes(ev.k));
    if (li >= 0) this.laneHit[li] = now;
    this.pulse.set(ev.key, 1);
    this.kick = now;
    // 球上炸开一圈光点（从这个会话那条带往外飞）
    const band = Math.max(0, this.data.order.indexOf(ev.key)), n = Math.max(1, this.data.order.length);
    const y = 1 - (band + .5) / n * 2, col = kindColor(ev);
    for (let i = 0; i < 14; i++) this.sparks.push({ at: now, y, a: Math.random() * Math.PI * 2, v: .5 + Math.random() * .9, col });
    if (this.sparks.length > 300) this.sparks.splice(0, this.sparks.length - 300);
    if (ev.k === 'edit' || ev.k === 'write') this.codeAt = now;
  }

  tickSecond() {}
  set dirty(v) {}

  /// 球和两块滚动的每帧画，另外隔一帧（30 帧也看着顺）
  draw(now) {
    this.frame++;
    this.core(now);
    this.lanes(now);
    if (this.frame % 2) return;
    this.thought(now); this.matrix(now);
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
  /// 小标签 + 下面的数（参考视频里的 think 3.6s、in 316.3k 那种）
  stat(g, x, y, k, v, col, al) {
    g.textAlign = al; g.font = `9px ${MONO}`; g.fillStyle = '#5d6476'; g.fillText(k, x, y);
    g.font = `600 11.5px ${MONO}`; g.fillStyle = col; g.fillText(v, x, y + 14); g.textAlign = 'left';
  }

  // ── 思考流 ──
  thought(now) {
    const { g, w, h } = this.P.thought, G = this.data.G;
    if (!w) return;
    g.clearRect(0, 0, w, h);
    const x0 = 8, x1 = w - 8, busy = this.busy, span = x1 - x0;
    const xOf = (at) => x1 - (now - at) / WAVE_MS * span;
    // 上：思考——一条平滑起伏的紫线，每次想过一阵在那个时刻鼓起一个包；有会话在工作时一直轻轻起伏
    const thinks = this.live.filter(r => r.ev.th);
    const lastTh = thinks.length ? thinks[thinks.length - 1].ev : null;
    g.font = `9px ${MONO}`; g.fillStyle = '#9b8cff'; g.fillText(t('思考'), x0, 10);
    g.textAlign = 'right'; g.fillStyle = '#e6e8ef'; g.fillText(lastTh ? t('%@ 秒', lastTh.th.toFixed(1)) : '—', x1, 10); g.textAlign = 'left';
    const b1 = 32, amp = 3 + Math.min(3, busy);
    g.beginPath();
    for (let x = x0; x <= x1; x += 2) {
      const tm = now - (x1 - x) / span * WAVE_MS;
      let v = Math.sin(tm / 1700) * .5 + Math.sin(tm / 730 + 1.3) * .3 + Math.sin(tm / 3100) * .2;
      v *= busy ? 1 : .35;
      for (const r of thinks) { const d = (x - xOf(r.at)) / 18; if (Math.abs(d) < 3) v += Math.exp(-d * d) * Math.min(2.2, .6 + r.ev.th / 8); }
      g.lineTo(x, b1 - Math.max(-1.2, Math.min(2.6, v)) * amp);
    }
    g.strokeStyle = 'rgba(155,140,255,.25)'; g.lineWidth = 3.5; g.stroke();
    g.strokeStyle = '#a896ff'; g.lineWidth = 1.2; g.stroke();
    // 下：调用——红线，一次调用一个方波脉冲（宽 = 结果大小），刚来的那个亮
    g.font = `9px ${MONO}`; g.fillStyle = '#ff5a7a'; g.fillText(t('调用'), x0, 46);
    g.textAlign = 'right'; g.fillStyle = '#e6e8ef'; g.fillText(t('%@ 次/分', this.rate), x1, 46); g.textAlign = 'left';
    const b2 = 66, ph = 11;
    const pulses = this.live.map(r => [xOf(r.at), Math.min(16, 5 + Math.log2(1 + (r.ev.sz || 300) / 200) * 2), r.at]).filter(([x]) => x > x0 - 20).sort((a, b) => a[0] - b[0]);
    g.beginPath(); g.moveTo(x0, b2);
    let cx = x0;
    for (const [x, pw] of pulses) {
      const a = Math.max(cx, x - pw / 2), e = Math.min(x1, x + pw / 2);
      if (e <= a) continue;
      g.lineTo(a, b2); g.lineTo(a + 1.5, b2 - ph); g.lineTo(e - 1.5, b2 - ph); g.lineTo(e, b2); cx = e;
    }
    g.lineTo(x1, b2);
    g.strokeStyle = 'rgba(255,90,122,.25)'; g.lineWidth = 3.5; g.stroke();
    g.strokeStyle = '#ff5a7a'; g.lineWidth = 1.2; g.stroke();
    const fresh = pulses.length ? pulses[pulses.length - 1] : null;
    if (fresh && now - fresh[2] < 1500) { const f = 1 - (now - fresh[2]) / 1500; g.fillStyle = `rgba(255,140,170,${f * .8})`; g.beginPath(); g.arc(fresh[0], b2 - ph, 2 + f * 3, 0, 7); g.fill(); }

    // 热度格：一行一个会话（最多 8 个），一列 2 秒，整片往左滚，右边一根亮的扫描线
    const hy = 76, rows = 8, hh = Math.max(36, Math.min(64, h * .27)), ch = hh / rows;
    g.font = `9px ${MONO}`; g.fillStyle = '#5d6476'; g.fillText(t('调用热度'), x0, hy - 2);
    const cols = Math.max(20, Math.floor(span / 7)), cw = span / cols, frac = (now % HEAT_COL_MS) / HEAT_COL_MS;
    const keys = this.data.order.slice(0, rows), heat = keys.map(() => new Array(cols + 2).fill(0));
    for (const { at, ev } of this.live) {
      const r = keys.indexOf(ev.key); if (r < 0) continue;
      const c = Math.floor((now - at) / HEAT_COL_MS); if (c > cols + 1) continue;
      heat[r][c] += 1 + Math.log2(1 + (ev.sz || 200) / 400);
    }
    const colAt = Math.floor(now / HEAT_COL_MS);
    for (let r = 0; r < rows; r++) {
      const s = this.data.sessions.get(keys[r]), work = s && (s.activity === 'busy' || s.activity === 'waiting');
      for (let c = 0; c <= cols; c++) {
        const x = x1 - (c + frac) * cw;
        if (x < x0 - cw) continue;
        // 底纹：每格一点固定的明暗（随列一起滚），在工作的会话那行更亮一档
        const base = hash(colAt - c, r) * (work ? 1.6 : .9);
        const v = (heat[r]?.[c] || 0) * 1.4 + base;
        const lv = Math.min(HEAT.length - 1, v), i = Math.floor(lv);
        g.fillStyle = HEAT[i]; g.globalAlpha = .55 + (lv - i) * .45;
        g.fillRect(Math.max(x0, x), hy + 2 + r * ch, cw - 1 - Math.max(0, x0 - x), ch - 1);
      }
    }
    g.globalAlpha = 1;
    const kick = Math.max(0, 1 - (now - this.kick) / 800);
    g.fillStyle = `rgba(255,255,255,${.55 + kick * .45})`; g.fillRect(x1 - 1, hy + 1, 1.5, hh + 2);
    g.fillStyle = `rgba(180,160,255,${.15 + kick * .2})`; g.fillRect(x1 - 5, hy + 1, 5, hh + 2);

    // 日志：一行一次调用，新的从下面挤进来、整列往上滚
    const ly = hy + hh + 16, lh = 11.5, room = Math.max(1, Math.floor((h - ly + 4) / lh));
    g.font = `9px ${MONO}`; g.fillStyle = '#5d6476'; g.fillText(t('事件'), x0, ly - 4);
    const list = G.recent.slice(-room - 1);
    const last = list[list.length - 1], slide = last && now - last.at < 260 ? (1 - (now - last.at) / 260) * lh : 0;
    g.save(); g.beginPath(); g.rect(0, ly - 1, w, h - ly + 1); g.clip();
    list.forEach((r, i) => {
      const y = ly + 8 + (i - (list.length - room)) * lh + slide;
      const col = kindColor(r.ev), newest = i === list.length - 1, glow = newest && r.at > 0 ? Math.max(0, 1 - (now - r.at) / 2000) : 0;
      if (glow) { g.fillStyle = rgba(col, glow * .14); g.fillRect(x0 - 4, y - 8.5, span + 8, lh); }
      g.font = `8.5px ${MONO}`; g.fillStyle = '#353a48'; g.textAlign = 'right'; g.fillText(String((G.calls - (list.length - 1 - i)) % 1000).padStart(3, '0'), x0 + 16, y); g.textAlign = 'left';
      g.font = `600 9px ${MONO}`; g.fillStyle = col; g.fillText(fit(g, t(VERB[r.ev.k] || '命令'), 40), x0 + 22, y);
      g.font = `9px ${MONO}`; g.fillStyle = newest ? '#ffffff' : '#b4b9c6';
      g.fillText(fit(g, r.ev.k === 'user' ? r.ev.label : (r.ev.w[0] || r.ev.r[0] || r.ev.label), span - 92), x0 + 66, y);
      const bw = Math.min(14, 3 + Math.log2(1 + (r.ev.sz || 100) / 100) * 2);
      g.fillStyle = col; g.globalAlpha = .8; g.fillRect(x1 - bw, y - 4, bw, 2.5); g.globalAlpha = 1;
    });
    g.restore();
    document.getElementById('fd-thought-n').textContent = t('%@ 个会话在工作', busy);
  }

  // ── 工具通道 ──
  lanes(now) {
    const { g, w, h } = this.P.lanes, G = this.data.G;
    if (!w) return;
    g.clearRect(0, 0, w, h);
    const counts = LANES.map(([, ks]) => ks.reduce((a, k) => a + (G.by[k] || 0), 0));
    const laneH = h * .5, fits = Math.max(4, Math.floor((laneH - 6) / 11));
    // 放不下全部 12 条：留调用最多的几条，顺序不变
    const keep = new Set(LANES.map((_, i) => i).sort((a, b) => counts[b] - counts[a]).slice(0, fits));
    const shown = LANES.map((l, i) => [l, i]).filter(([, i]) => keep.has(i));
    const rowH = Math.min(14, (laneH - 6) / shown.length);
    g.font = `9.5px ${MONO}`;
    const bx = Math.max(52, 22 + Math.max(...shown.map(([[name]]) => g.measureText(t(name)).width)) + 8);
    const px = w - 34;                                   // 扫描线
    shown.forEach(([[name, ks], i], row) => {
      const y = 4 + row * rowH, cy = y + rowH / 2, col = KIND_COLOR[ks[0]], age = now - this.laneHit[i], hot = age < 1800 ? 1 - age / 1800 : 0;
      // 圆点：刚被调用的实心亮着，其余空心暗
      g.beginPath(); g.arc(12, cy, 2.4, 0, 7);
      if (hot || counts[i]) { g.fillStyle = hot ? col : rgba(col, .45); g.fill(); } else { g.strokeStyle = '#3a3f4d'; g.lineWidth = 1; g.stroke(); }
      g.font = `9.5px ${MONO}`; g.fillStyle = hot ? '#ffffff' : counts[i] ? '#aab0bd' : '#4a5060'; g.textAlign = 'left'; g.fillText(t(name), 20, cy + 3.5);
      // 横条：这条通道上每次调用一段，从扫描线处出现、往左滑走（越老越暗）
      for (const { at, ev } of this.live) {
        if (!ks.includes(ev.k)) continue;
        const x = px - (now - at) / LANE_MS * (px - bx);
        // 还在跑的调用：横条从发出那一刻一直连到扫描线，跟着时间往右长，头上一直亮着
        const run = ev.toolId && this.data.pending.get(ev.toolId) === ev;
        const len = run ? Math.max(8, px - x) : Math.min(46, 8 + Math.log2(1 + (ev.sz || 200) / 120) * 5);
        if (x + len < bx) continue;
        const grow = Math.min(1, (now - at) / 300), a = Math.max(bx, x), e = Math.min(px, x + len * grow);
        if (e <= a) continue;
        g.fillStyle = ev.err ? '#ff4d6a' : col; g.globalAlpha = .35 + .55 * Math.max(0, 1 - (now - at) / LANE_MS);
        g.fillRect(a, cy - rowH * .26, e - a, rowH * .52);
        if (run) { g.globalAlpha = .65 + .35 * Math.sin(now / 160); g.fillStyle = '#ffffff'; g.fillRect(e - 3, cy - rowH * .26, 3, rowH * .52); }
        else if (now - at < 600) { g.globalAlpha = 1 - (now - at) / 600; g.fillStyle = '#ffffff'; g.fillRect(e - 3, cy - rowH * .26, 3, rowH * .52); }
      }
      g.globalAlpha = 1;
      g.font = `9.5px ${MONO}`; g.textAlign = 'right'; g.fillStyle = hot ? col : '#c8ccd6';
      g.fillText(Math.round(this.roll('lane' + i, counts[i])), w - 6, cy + 3.5); g.textAlign = 'left';
    });
    const kick = Math.max(0, 1 - (now - this.kick) / 700), lb = 4 + shown.length * rowH;
    g.fillStyle = `rgba(255,255,255,${.4 + kick * .6})`; g.fillRect(px, 2, 1.2, lb - 2);

    // 吞吐：每分钟调用（黄色大数字）+ 最近 60 秒直方图（一秒一格往左滚，白色短横是慢慢落下的峰值）
    const ty = lb + 12;
    g.font = `9px ${MONO}`; g.fillStyle = '#5d6476'; g.fillText(t('吞吐'), 8, ty);
    g.font = `700 15px ${MONO}`; g.fillStyle = '#e8f25a'; g.textAlign = 'right';
    const unit = t('次/分'); g.save(); g.font = `9px ${MONO}`; const uw = g.measureText(unit).width; g.restore();
    g.fillText(String(Math.round(this.roll('rate', this.rate))), w - 10 - uw, ty + 3);
    g.font = `9px ${MONO}`; g.fillStyle = '#7d8496'; g.fillText(unit, w - 6, ty + 3); g.textAlign = 'left';
    const hx = 8, hw = w - 16, hb = h - 32, hh = Math.max(14, hb - ty - 10), bins = new Array(HIST_N + 2).fill(0), frac = (now % 1000) / 1000, bw = hw / HIST_N;
    for (const { at } of this.live) { const k = Math.floor((now - at) / 1000); if (k <= HIST_N + 1) bins[k]++; }
    // 峰值记在「哪一秒」上，跟着那一格一起往左滚
    const sec = Math.floor(now / 1000);
    if (this.peakSec !== sec) { const d = this.peakSec === undefined ? 0 : Math.min(HIST_N + 2, sec - this.peakSec); for (let k = 0; k < d; k++) { this.peak.pop(); this.peak.unshift(0); } this.peakSec = sec; }
    const hm = Math.max(3, ...bins);
    for (let k = 0; k <= HIST_N; k++) {
      const x = hx + hw - (k + frac) * bw;
      if (x < hx) continue;
      // 底下暗灰的柱：相邻几秒的均值，看着像参考里叠在后面的那层
      const avg = ((bins[k - 1] || 0) + bins[k] + (bins[k + 1] || 0)) / 3;
      if (avg) { g.fillStyle = 'rgba(120,110,140,.28)'; const ah = avg / hm * hh; g.fillRect(x, hb - ah, bw - 1, ah); }
      const v = bins[k];
      this.peak[k] = Math.max(this.peak[k] * .995, v);
      if (v) { const bh = v / hm * hh; g.fillStyle = k === 0 ? '#ffd0e6' : k < 3 ? '#ff6f9f' : '#d63a74'; g.fillRect(x, hb - bh, bw - 1, bh); }
      if (this.peak[k] > .2) { g.fillStyle = 'rgba(255,255,255,.85)'; g.fillRect(x, hb - this.peak[k] / hm * hh - 3, bw - 1, 1.3); }
    }
    g.fillStyle = 'rgba(255,255,255,.08)'; g.fillRect(hx, hb, hw, 1);
    // 底部三个统计：标签、数字、彩色下划条
    const stats = [[t('读文件'), (G.by.read || 0) + (G.by.grep || 0), '#ff5a7a'], [t('改动'), (G.by.edit || 0) + (G.by.write || 0), '#f2cf5b'], [t('测试'), (G.by.test || 0) + (G.by.build || 0), '#f0a35e']];
    const sm = Math.max(1, ...stats.map(s => s[1]));
    stats.forEach(([k, v, col], i) => {
      const x = 8 + i * (w - 16) / 3, sw = (w - 16) / 3 - 10;
      g.font = `8.5px ${MONO}`; g.fillStyle = '#5d6476'; g.fillText(k, x, h - 20);
      g.font = `600 10.5px ${MONO}`; g.fillStyle = col; g.fillText(String(Math.round(this.roll('st' + i, v))), x, h - 8);
      g.fillStyle = 'rgba(255,255,255,.06)'; g.fillRect(x, h - 4, sw, 2);
      g.fillStyle = col; g.fillRect(x, h - 4, sw * Math.max(.06, v / sm), 2);
    });
    document.getElementById('fd-lanes-n').textContent = t('%@ 条通道', LANES.length);
  }

  // ── 模型核心 ──
  core(now) {
    const { g, w, h } = this.P.core, G = this.data.G;
    if (!w) return;
    g.clearRect(0, 0, w, h);
    const keys = this.data.order, n = Math.max(1, keys.length), busy = this.busy;
    const kick = Math.max(0, 1 - (now - this.kick) / 1400);
    const codeH = h > 205 ? Math.min(78, h * .36) : 0;
    const cx = w / 2, cy = (h - codeH) * .46, R0 = Math.min(w * .17, (h - codeH) * .36), rot = now / (busy ? 3200 : 5200);
    // 中心品红光晕：一直轻轻呼吸，来调用时一下变亮
    const breathe = .5 + .5 * Math.sin(now / 700);
    const halo = g.createRadialGradient(cx, cy, 0, cx, cy, R0 * .9);
    halo.addColorStop(0, `rgba(255,120,230,${.35 + breathe * .15 + kick * .45})`); halo.addColorStop(.25, `rgba(190,80,220,${.16 + kick * .2})`); halo.addColorStop(1, 'rgba(120,60,200,0)');
    g.fillStyle = halo; g.beginPath(); g.arc(cx, cy, R0 * .9, 0, 7); g.fill();
    // 外圈一道很淡的轮廓
    g.strokeStyle = 'rgba(160,150,220,.12)'; g.lineWidth = 1; g.beginPath(); g.arc(cx, cy, R0 * 1.02, 0, 7); g.stroke();
    // 点阵球：白点，一个会话一条纬度带，刚调用的那条带亮成粉色
    const bands = keys.map((k, i) => {
      const s = this.data.sessions.get(k), p = this.pulse.get(k) || 0;
      const work = s && (s.activity === 'busy' || s.activity === 'waiting') ? .18 + .12 * Math.sin(now / 500 + i) : 0;
      return Math.max(p, work);
    });
    const tilt = .38;
    for (const [x, y, z] of this.sphere) {
      const X = x * Math.cos(rot) - z * Math.sin(rot), Z0 = x * Math.sin(rot) + z * Math.cos(rot);
      const Y = y * Math.cos(tilt) - Z0 * Math.sin(tilt), Z = y * Math.sin(tilt) + Z0 * Math.cos(tilt);
      const p = bands[Math.min(n - 1, Math.floor((1 - y) / 2 * n))] || 0, depth = (Z + 1) / 2, sz = .7 + depth * 1.3 + p * 1.2;
      g.fillStyle = p > .25 ? `rgba(255,${Math.round(170 - p * 60)},225,${.25 + depth * .6})` : `rgba(235,232,255,${.08 + depth * .78})`;
      g.fillRect(cx + X * R0 - sz / 2, cy - Y * R0 - sz / 2, sz, sz);
    }
    for (const [k, v] of this.pulse) this.pulse.set(k, v * .975);
    // 绕着转的几颗彩色小星
    [['#f2e25a', 1.32, 5200, 0], ['#5fe0e8', 1.5, 7400, 2], ['#ff7fb8', 1.22, 4300, 4]].forEach(([col, rr, per, ph]) => {
      const a = now / per * Math.PI * 2 + ph, ox = cx + Math.cos(a) * R0 * rr, oy = cy + Math.sin(a) * R0 * rr * .55;
      const gl = g.createRadialGradient(ox, oy, 0, ox, oy, 5); gl.addColorStop(0, col); gl.addColorStop(1, rgba(col, 0));
      g.fillStyle = gl; g.beginPath(); g.arc(ox, oy, 5, 0, 7); g.fill();
      g.fillStyle = '#fff'; g.fillRect(ox - .8, oy - .8, 1.6, 1.6);
    });
    // 炸开的光点
    for (let i = this.sparks.length - 1; i >= 0; i--) {
      const sp = this.sparks[i], age = (now - sp.at) / 1300;
      if (age >= 1) { this.sparks.splice(i, 1); continue; }
      const r = R0 * Math.sqrt(Math.max(0, 1 - sp.y * sp.y)), d = 1 + age * sp.v * .8;
      const pxx = cx + Math.cos(sp.a + rot) * r * d, pyy = cy - sp.y * R0 * (1 + age * .2) + Math.sin(sp.a + rot) * r * .25 * d;
      g.fillStyle = rgba(sp.col, (1 - age) * .9); g.beginPath(); g.arc(pxx, pyy, 1.5 * (1 - age) + .5, 0, 7); g.fill();
    }
    // 球下面的状态字：字母间距拉开、末尾的点一个个冒出来
    const live = busy || now - this.kick < 4000;
    const word = live ? t('工作中') : t('空闲'), dots = '.'.repeat(Math.floor(now / 450) % 4);
    g.textAlign = 'center'; g.font = `600 9.5px ${MONO}`; g.fillStyle = live ? '#5fe8d8' : '#6b7282';
    g.fillText(word + dots.padEnd(3, ' '), cx, cy + R0 + 15);
    // 两边的数
    const sess = [...this.data.sessions.values()];
    const cache = cacheRatio(sess), tot = this.data.usage?.totals || {};
    let done = 0, all = 0; for (const s of sess) if (s.stage) { all += s.stage.total; done += s.stage.step; }
    const lastTh = [...this.live].reverse().find(r => r.ev.th)?.ev;
    const top = 12, gap = Math.min(36, (h - codeH - 20) / 3);
    this.stat(g, 10, top, t('思考'), lastTh ? lastTh.th.toFixed(1) + 's' : '—', '#e6e8ef', 'left');
    this.stat(g, 10, top + gap, t('步骤'), all ? `${done}/${all}` : '—', '#e6e8ef', 'left');
    this.stat(g, 10, top + gap * 2, t('缓存'), cache === null ? '—' : Math.round(cache * 100) + '%', '#e6e8ef', 'left');
    this.stat(g, w - 10, top, t('输入'), fmtTok(this.roll('in', (tot.input || 0) + (tot.cacheRead || 0) + (tot.cacheWrite || 0))), '#e8f25a', 'right');
    this.stat(g, w - 10, top + gap, t('输出'), fmtTok(this.roll('out', tot.output || 0)), '#5fe0e8', 'right');
    this.stat(g, w - 10, top + gap * 2, t('调用'), String(Math.round(this.roll('calls', G.calls))), '#ff5a7a', 'right');
    if (this.frame % 30 === 1) { const el = document.getElementById('fd-core-n'); const m = sess.map(x => x.model).find(Boolean) || ''; if (el && el.textContent !== m) el.textContent = m; }
    // 代码：最近一次改的代码逐字敲出来，带行号和简单的着色，敲满了往上滚，红色光标
    const lc = G.lastCode;
    if (lc && codeH) {
      const sig = lc.file + lc.lines.join('\n');
      if (sig !== this.codeSig) { this.codeSig = sig; if (!this.codeAt) this.codeAt = now - 1e5; }
      const y0 = h - codeH + 10, all2 = lc.lines.join('\n'), k = Math.min(all2.length, Math.floor((now - this.codeAt) / 22));
      g.font = `9px ${MONO}`; g.fillStyle = '#5d6476'; g.fillText(fit(g, lc.file, w * .6), 10, y0);
      g.textAlign = 'right'; g.fillText(t('%@ 行', lc.lines.length), w - 10, y0); g.textAlign = 'left';
      const typed = all2.slice(0, k).split('\n'), room = Math.max(1, Math.floor((codeH - 16) / 11.5)), first = Math.max(0, typed.length - room);
      g.save(); g.beginPath(); g.rect(0, y0 + 3, w, codeH); g.clip();
      typed.slice(first).forEach((ln, i) => {
        const y = y0 + 14 + i * 11.5;
        g.font = `8.5px ${MONO}`; g.fillStyle = '#353a48'; g.textAlign = 'right'; g.fillText(String(first + i + 1), 24, y); g.textAlign = 'left';
        drawCode(g, ln, 32, y, w - 44);
        if (i === typed.length - 1 - first && Math.floor(now / 380) % 2) { g.fillStyle = '#ff4d6a'; g.fillRect(32 + Math.min(w - 50, g.measureText(ln).width) + 1, y - 7.5, 5, 9); }
      });
      g.restore();
    }
  }

  // ── 检查矩阵 ──
  matrix(now) {
    const { g, w, h } = this.P.matrix, G = this.data.G;
    if (!w) return;
    g.clearRect(0, 0, w, h);
    const all = G.testPass + G.testFail, fail = !!G.testFail && !(G.checks.length && G.checks[G.checks.length - 1].ok);
    let running = 0; for (const ev of this.data.pending.values()) if (ev.k === 'test' || ev.k === 'build') running++;
    // 右上角图例：通过 / 在跑 / 失败
    const leg = [['#b8f03c', G.testPass + G.builds - G.buildFail], ['#f2cf5b', running], ['#ff4d6a', G.testFail + G.buildFail]];
    g.font = `8.5px ${MONO}`; g.textAlign = 'right';
    leg.forEach(([col, v], i) => { g.fillStyle = col; g.fillRect(w - 34, 8 + i * 11, 5, 5); g.fillStyle = '#c8ccd6'; g.fillText(String(v), w - 8, 13 + i * 11); });
    g.textAlign = 'left';
    // 等距平台：最近 48 次检查一格一个；在跑的冒黄方块，刚通过的黄方块沉回平台，没修好的失败是叠起来的红方块
    const narrow = w < 300, cols = 8, rows = 6, s = Math.min(narrow ? 7 : 10.5, (w * .62) / (cols + rows) / .92);
    const ox = w * (narrow ? .5 : .46), oy = 18 + s * .2, th = s * .62;
    const iso = (c, r) => [ox + (c - r) * s * .92, oy + (c + r) * s * .53];
    const cube = (c, r, z, hh, top, l, rr) => {
      const [x, y0] = iso(c + .5, r + .5), y = y0 - z;
      g.fillStyle = l; g.beginPath(); g.moveTo(x - s * .46, y); g.lineTo(x, y + s * .265); g.lineTo(x, y + s * .265 - hh); g.lineTo(x - s * .46, y - hh); g.fill();
      g.fillStyle = rr; g.beginPath(); g.moveTo(x + s * .46, y); g.lineTo(x, y + s * .265); g.lineTo(x, y + s * .265 - hh); g.lineTo(x + s * .46, y - hh); g.fill();
      g.fillStyle = top; g.beginPath(); g.moveTo(x, y - s * .265 - hh); g.lineTo(x + s * .46, y - hh); g.lineTo(x, y + s * .265 - hh); g.lineTo(x - s * .46, y - hh); g.fill();
    };
    // 平台本体（一整块，带厚度）
    const [ax, ay] = iso(0, 0), [bx2, by2] = iso(cols, 0), [cx2, cy2] = iso(cols, rows), [dx, dy] = iso(0, rows);
    const lime = fail ? '#9ec43a' : '#b8f03c';
    g.fillStyle = '#6f9a22'; g.beginPath(); g.moveTo(dx, dy); g.lineTo(cx2, cy2); g.lineTo(cx2, cy2 + th); g.lineTo(dx, dy + th); g.fill();
    g.fillStyle = '#56781a'; g.beginPath(); g.moveTo(cx2, cy2); g.lineTo(bx2, by2); g.lineTo(bx2, by2 + th); g.lineTo(cx2, cy2 + th); g.fill();
    g.fillStyle = lime; g.beginPath(); g.moveTo(ax, ay); g.lineTo(bx2, by2); g.lineTo(cx2, cy2); g.lineTo(dx, dy); g.fill();
    // 一道光斜着扫过平台
    const sweep = (now / 2600) % 1.6 - .3;
    g.save(); g.beginPath(); g.moveTo(ax, ay); g.lineTo(bx2, by2); g.lineTo(cx2, cy2); g.lineTo(dx, dy); g.clip();
    const sx = ax + (cx2 - ax) * sweep, sg = g.createLinearGradient(sx - 30, 0, sx + 30, 0);
    sg.addColorStop(0, 'rgba(255,255,255,0)'); sg.addColorStop(.5, 'rgba(255,255,255,.22)'); sg.addColorStop(1, 'rgba(255,255,255,0)');
    g.fillStyle = sg; g.fillRect(sx - 30, 0, 60, h); g.restore();
    // 方块：从后往前画（先远后近）
    const list = G.checks.slice(-cols * rows), cells = [];
    const fixedAfter = new Set(); for (let i = list.length - 1; i >= 0; i--) { if (list[i].ok) fixedAfter.add(list[i].key); else if (fixedAfter.has(list[i].key)) list[i].fixed = true; }
    list.forEach((it, i) => {
      if (!this.checkAt.has(it)) this.checkAt.set(it, now);
      const age = now - this.checkAt.get(it);
      if (it.ok && age < 1400) cells.push([i, 'sink', age / 1400]);
      else if (!it.ok && !it.fixed) cells.push([i, 'red', Math.min(1, age / 500)]);
    });
    for (let k = 0; k < Math.min(running, 6); k++) cells.push([list.length + k, 'run', Math.min(1, ((now / 600) + k * .3) % 1 + .4)]);
    cells.sort((a, b) => { const ca = a[0] % (cols * rows), cb = b[0] % (cols * rows); return (ca % cols + Math.floor(ca / cols)) - (cb % cols + Math.floor(cb / cols)); });
    for (const [i, kind, u] of cells) {
      const idx = i % (cols * rows), c = idx % cols, r = Math.floor(idx / cols);
      if (kind === 'red') { const e = 1 - Math.pow(1 - u, 3); cube(c, r, 0, s * .85 * e, '#ff6b7a', '#c23a4c', '#922a38'); cube(c, r, s * .85 * e, s * .75 * e, '#ff8a96', '#d8475a', '#a83343'); }
      else if (kind === 'run') { const bob = Math.sin(now / 260 + i) * 1.5; cube(c, r, 0, s * .8 + bob, '#ffe27a', '#d4a52c', '#a88020'); }
      else { const e = 1 - u; cube(c, r, 0, s * .8 * e, mix('#ffe27a', '#d8ff6a', u), '#c9b030', '#9d8a22'); }
    }
    // 大比分 + 胶囊
    const by = h * .62;
    g.font = `9px ${MONO}`; g.fillStyle = '#5d6476'; g.fillText(t('测试通过'), 10, by - 22);
    g.font = `700 ${narrow ? 20 : 26}px ${MONO}`; g.fillStyle = fail ? '#ff4d6a' : '#c8f53c';
    g.fillText(`${Math.round(this.roll('pass', G.testPass))}/${Math.round(this.roll('all', all))}`, 10, by);
    const tag = fail ? t('有失败') : t('可以合并');
    g.font = `700 9px ${MONO}`; const tw = g.measureText(tag).width + 16, tx = w - tw - 10, tyy = by - 15;
    g.strokeStyle = fail ? 'rgba(255,77,106,.8)' : '#c8f53c'; g.fillStyle = fail ? 'rgba(255,77,106,.12)' : 'rgba(200,245,60,.08)'; g.lineWidth = 1.2;
    roundRect(g, tx, tyy, tw, 17, 8.5); g.fill(); g.stroke();
    g.fillStyle = fail ? '#ff8a96' : '#c8f53c'; g.fillText(tag, tx + 8, tyy + 12);
    // 环形通过率
    const rate = all ? G.testPass / all : 0, rx = 26, ry = h - 30, shownRate = this.roll('prate', rate * 1000) / 1000, ringCol = fail ? '#ff4d6a' : '#c8f53c';
    g.lineWidth = 4; g.strokeStyle = 'rgba(255,255,255,.07)'; g.beginPath(); g.arc(rx, ry, 15, 0, 7); g.stroke();
    g.strokeStyle = ringCol; g.beginPath(); g.arc(rx, ry, 15, -Math.PI / 2, -Math.PI / 2 + shownRate * Math.PI * 2); g.stroke();
    g.font = `600 8.5px ${MONO}`; g.fillStyle = '#e6e8ef'; g.textAlign = 'center'; g.fillText(all ? Math.round(shownRate * 100) + '%' : '—', rx, ry + 3);
    g.font = `8px ${MONO}`; g.fillStyle = '#5d6476'; g.fillText(t('通过率'), rx, h - 4); g.textAlign = 'left';
    // 每次检查用时：紫色柱，最新一根亮黄
    const ds = G.checks.slice(-40), dm = Math.max(2, ...ds.map(x => x.d)), bx = 54, bwid = w - bx - 10, bh0 = Math.max(16, h - by - 34);
    g.font = `8.5px ${MONO}`; g.fillStyle = '#5d6476'; g.fillText(t('检查用时'), bx, by + 14);
    const lastD = ds.length ? ds[ds.length - 1].d : 0;
    g.textAlign = 'right'; g.fillStyle = '#e6e8ef'; g.fillText(lastD ? lastD.toFixed(1) + 's' : '—', w - 10, by + 14); g.textAlign = 'left';
    ds.forEach((x, i) => {
      const grow = Math.min(1, (now - (this.checkAt.get(x) ?? 0)) / 600), bh = Math.max(2, Math.log2(1 + x.d) / Math.log2(1 + dm) * bh0) * grow;
      g.fillStyle = i === ds.length - 1 ? '#f2e25a' : x.ok ? '#7a6cf0' : '#ff4d6a';
      g.fillRect(bx + i * bwid / 40, h - 12 - bh, bwid / 40 - 1.2, bh);
    });
    g.font = `8px ${MONO}`; g.fillStyle = '#5d6476'; g.fillText(t('失败 %@', G.testFail + G.buildFail), bx, h - 2);
    document.getElementById('fd-matrix-n').textContent = t('%@ 次检查', G.checks.length);
    if (this.checkAt.size > 600) this.checkAt = new Map([...this.checkAt].slice(-300));
  }
}

function roundRect(g, x, y, w, h, r) { g.beginPath(); g.moveTo(x + r, y); g.arcTo(x + w, y, x + w, y + h, r); g.arcTo(x + w, y + h, x, y + h, r); g.arcTo(x, y + h, x, y, r); g.arcTo(x, y, x + w, y, r); g.closePath(); }
function mix(a, b, u) { const A = parseInt(a.slice(1), 16), B = parseInt(b.slice(1), 16); const c = (s) => Math.round(((A >> s) & 255) * (1 - u) + ((B >> s) & 255) * u); return `rgb(${c(16)},${c(8)},${c(0)})`; }
/// 一行代码简单着色：关键字粉、字符串黄、数字青、其余白
function drawCode(g, ln, x, y, maxW) {
  g.font = `9px ${MONO}`;
  const parts = [], re = /("[^"]*"?|'[^']*'?|`[^`]*`?)|(\b\d+(?:\.\d+)?\b)|(\/\/.*|#.*)/g;
  let last = 0, m;
  while ((m = re.exec(ln))) { if (m.index > last) parts.push([ln.slice(last, m.index), 0]); parts.push([m[0], m[1] ? 1 : m[2] ? 2 : 3]); last = re.lastIndex; }
  if (last < ln.length) parts.push([ln.slice(last), 0]);
  let cx = x;
  for (const [txt, kind] of parts) {
    if (cx - x > maxW) break;
    if (kind) { g.fillStyle = kind === 1 ? '#f2e25a' : kind === 2 ? '#5fe0e8' : '#5d6476'; g.fillText(txt, cx, y); cx += g.measureText(txt).width; continue; }
    // 普通段里再挑关键字
    let l2 = 0; KW.lastIndex = 0; let k;
    while ((k = KW.exec(txt))) {
      const pre = txt.slice(l2, k.index); g.fillStyle = '#d8dbe4'; g.fillText(pre, cx, y); cx += g.measureText(pre).width;
      g.fillStyle = '#ff5f8f'; g.fillText(k[0], cx, y); cx += g.measureText(k[0]).width; l2 = KW.lastIndex;
    }
    const rest = txt.slice(l2); g.fillStyle = '#d8dbe4'; g.fillText(rest, cx, y); cx += g.measureText(rest).width;
  }
}
