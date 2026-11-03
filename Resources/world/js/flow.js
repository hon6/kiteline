// 数据流大屏：所有会话一块屏。左边是它们读进来的东西，中间一列是每个会话，右边是做的事和产出去了哪；
// 每次工具调用画一串线穿过各列（一次一根，越忙越密），发生时一道亮光带着星芒沿线走一趟。
// 卡片铺在一张带格子的画布上，镜头会自己 2D 运镜：平移、推近到正在忙的那张卡、旁边列出它最近的调用，再拉回全景。
// 和世界共用一套宿主（Mac / iPhone 的 WKWebView、Windows 的 WebView2、Linux 浏览器直连），消息协议同 docs/world.md 第 9 节，
// 另外会去 api/history 补每个会话最近的调用，一打开就是满的。

import * as THREE from '../vendor/three.module.min.js';
import { OrbitControls } from '../vendor/addons/controls/OrbitControls.js';
import { FlowData, top, baseName, cacheRatio } from './flowdata.js';
import { Dash, fmtTok, sayOf, VERB, kindColor } from './flowdash.js';
import { setStrings, t } from './i18n.js';

const DW = 1440, DH = 780, D = 7;      // 设计尺寸（一个单位 = 一个设计像素）、卡片厚度
const BUS_X = 262, SES_X = 560, SES_W = 214, MAXS = 37;   // 中间那列最多放几张（只留标题条时一张 20 高），再多合成「其余 N 个会话」
const SEG = 22;                          // 每根曲线分几段
const MAXP = 1500;                       // 同时在走的光点上限
const LITN = 320;                        // 同时亮着的线（有光点在走的那几根）上限
const SEG_MS = 360;                      // 光点走一段线要多久
const host = {
  connected: !!(window.webkit?.messageHandlers?.world || window.chrome?.webview),
  post(msg) {
    try {
      if (window.webkit?.messageHandlers?.world) window.webkit.messageHandlers.world.postMessage(msg);
      else if (window.chrome?.webview) window.chrome.webview.postMessage(msg);
    } catch { /* 主程序不在：演示 */ }
  },
};
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const ease = (u) => (u < 0.5 ? 4 * u * u * u : 1 - Math.pow(-2 * u + 2, 3) / 2);
const W = (x, y, z = 0) => new THREE.Vector3(x - DW / 2, DH / 2 - y, z);
function rng(seed) { let s = seed >>> 0 || 1; return () => ((s = Math.imul(s ^ (s >>> 15), 2246822507) ^ Math.imul(s ^ (s >>> 13), 3266489909), (s >>> 0) / 4294967296)); }
const pct = (a, b) => (b ? Math.min(1, a / b) : 0);
const R = (l, v, r, extra = {}) => ({ l, v, r, ...extra });

const COLORS = { teal: '#5fe0c8', green: '#8be37c', yellow: '#f2cf5b', orange: '#f0a35e', pink: '#ff5fa8', violet: '#9b8cff', blue: '#6ea8ff', red: '#ff5a6a' };
// 线是淡淡的灰（只带一点色相），普通叠加：叠再多也只是这层淡色，不会越叠越亮（11-02：线要淡、偏灰，光点才显眼）
const LINE = {
  hair: { color: new THREE.Color('#5c6270'), a: .16, hot: '#ffffff', lift: [0, 3], cap: 640 },
  pink: { color: new THREE.Color('#7a6070'), a: .2, hot: '#ff8cc6', lift: [0, 4], cap: 480 },
  yel: { color: new THREE.Color('#78725c'), a: .2, hot: '#ffe27a', lift: [0, 4], cap: 380 },
  teal: { color: new THREE.Color('#5c7672'), a: .2, hot: '#8ff5e2', lift: [0, 3], cap: 280 },
};

// ── 卡片 ──
class Card {
  constructor(flow, def) {
    Object.assign(this, def);
    this.flow = flow; this.heat = 0; this.fires = []; this.lines = 0;
    this.rowsN = def.rowsN;
    this.h = 19 + (this.rowsN ? 5 + this.rowsN * 15 + 6 : 0);
    this.scale = flow.texScale;
    this.canvas = document.createElement('canvas');
    this.canvas.width = Math.ceil(this.w * this.scale); this.canvas.height = Math.ceil(this.h * this.scale);
    this.g = this.canvas.getContext('2d');
    this.tex = new THREE.CanvasTexture(this.canvas);
    this.tex.colorSpace = THREE.SRGBColorSpace;
    this.tex.anisotropy = 4;
    const side = new THREE.MeshBasicMaterial({ color: new THREE.Color(this.color).multiplyScalar(.32) });
    const back = new THREE.MeshBasicMaterial({ color: 0x0b0d13 });
    const face = new THREE.MeshBasicMaterial({ map: this.tex });
    this.mesh = new THREE.Mesh(new THREE.BoxGeometry(this.w, this.h, D), [side, side, side, side, face, back]);
    this.mesh.userData.card = this;
    this.glow = new THREE.Mesh(new THREE.PlaneGeometry(this.w + 40, this.h + 40), new THREE.MeshBasicMaterial({ map: flow.glowTex, color: new THREE.Color(this.color), transparent: true, opacity: 0, blending: THREE.AdditiveBlending, depthWrite: false }));
    flow.scene.add(this.mesh, this.glow);
    this.place(def.x, def.y);
    this.dirty = true;
  }
  place(x, y) {
    this.x = x; this.y = y;
    const c = W(x + this.w / 2, y + this.h / 2, D / 2);
    this.mesh.position.copy(c);
    this.glow.position.set(c.x, c.y, -.5);
  }
  get center() { return W(this.x + this.w / 2, this.y + this.h / 2, D); }
  rowY(i) { return this.y + (this.rowsN ? 19 + 5 + Math.min(i, this.rowsN - 1) * 15 + 7.5 : 9.5); }
  right(i) { return [this.x + this.w, this.rowY(i)]; }
  left(i) { return [this.x, this.rowY(i)]; }
  fire() { this.heat = 1; this.fires.push(performance.now()); if (this.fires.length > 60) this.fires.shift(); }
  score(now) { while (this.fires.length && now - this.fires[0] > 15000) this.fires.shift(); return this.fires.length; }

  draw() {
    const g = this.g, s = this.scale, w = this.w, h = this.h;
    g.setTransform(s, 0, 0, s, 0, 0);
    g.clearRect(0, 0, w, h);
    const idle = this.isIdle?.();
    g.fillStyle = 'rgba(13,15,22,0.96)'; g.fillRect(0, 0, w, h);
    g.strokeStyle = 'rgba(160,175,210,.22)'; g.lineWidth = 1; g.strokeRect(.5, .5, w - 1, h - 1);
    g.fillStyle = idle ? '#3a3340' : this.color; g.fillRect(0, 0, w, 19);
    const rows = this.rows();
    const em = this.em ? this.em() : '';
    g.textBaseline = 'middle';
    g.font = `600 10px ${MONO}`; const emW = em ? g.measureText(em).width + 8 : 0;
    g.font = `700 11px ${SANS}`; g.fillStyle = idle ? '#c9c3cf' : '#0a0b10';
    let x = 7;
    if (this.live !== undefined) { g.beginPath(); g.arc(10, 9.5, 3, 0, 7); g.fillStyle = idle ? '#6b6470' : '#0a0b10'; g.fill(); x = 18; g.fillStyle = idle ? '#c9c3cf' : '#0a0b10'; }
    const title = fitText(g, this.title, w - x - 8 - emW - (this.sub ? 40 : 0));
    g.fillText(title, x, 10);
    if (this.sub) { const tw = g.measureText(title).width; g.font = `600 9.5px ${MONO}`; g.globalAlpha = .62; g.fillText(fitText(g, this.sub, w - x - tw - 14 - emW), x + tw + 6, 10.5); g.globalAlpha = 1; }
    if (em) { g.font = `700 10px ${MONO}`; g.textAlign = 'right'; g.fillText(em, w - 7, 10.5); g.textAlign = 'left'; }
    rows.slice(0, this.rowsN).forEach((r, i) => {
      const y = 19 + 5 + i * 15 + 7.5, c = r.warn ? COLORS.red : r.good ? COLORS.green : this.color;
      g.fillStyle = c; g.globalAlpha = .75; g.fillRect(7, y - 2.5, 5, 5); g.globalAlpha = 1;
      if (r.wide) {
        g.font = `10px ${MONO}`; g.fillStyle = '#9aa1b2'; g.fillText(fitText(g, r.l, w - 26), 18, y + .5);
        return;
      }
      g.font = `10px ${SANS}`; g.fillStyle = '#9aa1b2'; g.fillText(fitText(g, r.l, 60), 18, y + .5);
      const bx = 82, bw = w - bx - 52;
      g.fillStyle = 'rgba(255,255,255,.07)'; g.fillRect(bx, y - 2, bw, 4);
      g.fillStyle = c; g.fillRect(bx, y - 2, Math.max(0, Math.min(1, r.r || 0)) * bw, 4);
      g.font = `10px ${MONO}`; g.fillStyle = '#e6e8ef'; g.textAlign = 'right'; g.fillText(String(r.v), w - 8, y + .5); g.textAlign = 'left';
      g.fillStyle = '#ffffff'; g.globalAlpha = .55; g.fillRect(w - 1.5, y - 1, 1.5, 2); g.globalAlpha = 1;
    });
    this.tex.needsUpdate = true;
    this.dirty = false;
  }
  dispose() { this.flow.scene.remove(this.mesh, this.glow); this.mesh.geometry.dispose(); this.tex.dispose(); this.glow.geometry.dispose(); }
}
const MONO = '"JetBrains Mono", ui-monospace, "SF Mono", Menlo, Consolas, monospace';
const SANS = '-apple-system, "PingFang SC", "Microsoft YaHei UI", "Noto Sans CJK SC", sans-serif';
function fitText(g, s, w) { s = String(s || ''); if (w <= 0) return ''; if (g.measureText(s).width <= w) return s; while (s.length > 1 && g.measureText(s + '…').width > w) s = s.slice(0, -1); return s + '…'; }

// ── 线：每种一组 LineSegments，环形写入（满了覆盖最早的） ──
class Bank {
  constructor(scene, kind) {
    this.kind = kind; this.spec = LINE[kind]; this.cap = this.spec.cap; this.next = 0; this.count = 0;
    const n = this.cap * SEG * 2;
    this.pos = new Float32Array(n * 3); this.col = new Float32Array(n * 3);
    this.owner = new Array(this.cap).fill(null);   // 每根线属于哪几张卡（运镜对准某张卡时它的线亮）
    this.boost = new Float32Array(this.cap).fill(1);
    const geo = new THREE.BufferGeometry();
    this.pa = new THREE.BufferAttribute(this.pos, 3).setUsage(THREE.DynamicDrawUsage);
    this.ca = new THREE.BufferAttribute(this.col, 3).setUsage(THREE.DynamicDrawUsage);
    geo.setAttribute('position', this.pa); geo.setAttribute('color', this.ca);
    geo.setDrawRange(0, 0);
    this.obj = new THREE.LineSegments(geo, new THREE.LineBasicMaterial({ vertexColors: true, transparent: true, opacity: this.spec.a, depthWrite: false }));
    this.obj.frustumCulled = false;
    scene.add(this.obj);
  }
  clear() { this.next = 0; this.count = 0; this.obj.geometry.setDrawRange(0, 0); this.owner.fill(null); }
  add(pts, owner) {
    const i = this.next; this.next = (this.next + 1) % this.cap; this.count = Math.min(this.cap, this.count + 1);
    const o = i * SEG * 2 * 3;
    for (let k = 0; k < SEG; k++) {
      const a = pts[k], b = pts[k + 1];
      this.pos.set([a.x, a.y, a.z, b.x, b.y, b.z], o + k * 6);
    }
    this.owner[i] = owner;
    this.paint(i, 1, true);
    this.pa.addUpdateRange(o, SEG * 6); this.pa.needsUpdate = true;
    this.obj.geometry.setDrawRange(0, this.count * SEG * 2);
    return i;
  }
  paint(i, boost, ranged) {
    this.boost[i] = boost;
    // 透明度在材质上（整组一样），这里只调亮度：对准别的卡时压暗
    const c = this.spec.color, o = i * SEG * 2 * 3;
    const r = c.r * boost, g = c.g * boost, b = c.b * boost;
    for (let k = 0; k < SEG * 2; k++) { this.col[o + k * 3] = r; this.col[o + k * 3 + 1] = g; this.col[o + k * 3 + 2] = b; }
    if (ranged) this.ca.addUpdateRange(o, SEG * 6);
    this.ca.needsUpdate = true;
  }
  focus(id) {
    // 一下子改很多根：整块重传，不逐段
    this.ca.clearUpdateRanges();
    for (let i = 0; i < this.count; i++) {
      const own = this.owner[i];
      const want = !id ? 1 : own && own.includes(id) ? 1 : .22;
      if (this.boost[i] !== want) this.paint(i, want);
    }
  }
  /// 第 i 根线的各点（光点沿已有的线走）
  pointsOf(i) {
    const o = i * SEG * 2 * 3, pts = [];
    for (let k = 0; k < SEG; k++) pts.push(new THREE.Vector3(this.pos[o + k * 6], this.pos[o + k * 6 + 1], this.pos[o + k * 6 + 2]));
    pts.push(new THREE.Vector3(this.pos[o + SEG * 6 - 3], this.pos[o + SEG * 6 - 2], this.pos[o + SEG * 6 - 1]));
    return pts;
  }
  countOf(id) { let n = 0; for (let i = 0; i < this.count; i++) if (this.owner[i]?.includes(id)) n++; return n; }
}

function curve(a, b, c1, c2, lift, z0) {
  const pts = [];
  for (let k = 0; k <= SEG; k++) {
    const u = k / SEG, v = 1 - u;
    const x = v * v * v * a[0] + 3 * v * v * u * c1[0] + 3 * v * u * u * c2[0] + u * u * u * b[0];
    const y = v * v * v * a[1] + 3 * v * v * u * c1[1] + 3 * v * u * u * c2[1] + u * u * u * b[1];
    pts.push(W(x, y, z0 + Math.sin(Math.PI * u) * lift));
  }
  return pts;
}

class Flow {
  constructor() {
    this.host = host;
    this.data = new FlowData();
    this.mediaBase = ''; this.mediaSuffix = '';
    this.active = true; this.visible = true;
    this.events = [];          // 画在屏上的调用（重排会话卡片时按它重画所有线）
    this.focusId = null; this.picked = null;
    this.shots = 0;
    try { this.auto = localStorage.getItem('flow.auto') !== '0'; } catch { this.auto = true; }
    this.pausedUntil = 0;

    const phone = Math.min(innerWidth, innerHeight) < 600;
    this.texScale = Math.min(3, Math.max(2, (devicePixelRatio || 1) * (phone ? 1.2 : 1.5)));
    this.canvas = $('flow-scene');
    this.renderer = new THREE.WebGLRenderer({ canvas: this.canvas, antialias: true, powerPreference: 'high-performance', stencil: false });
    this.pixelRatio = Math.min(devicePixelRatio || 1, 2);
    this.renderer.setPixelRatio(this.pixelRatio);
    this.scene = new THREE.Scene();
    this.scene.background = new THREE.Color('#06070b');
    this.camera = new THREE.PerspectiveCamera(32, 1, 5, 9000);
    this.controls = new OrbitControls(this.camera, this.canvas);
    // 纯 2D（11-02：运镜改 2D，不要 3D）：只能拖动、缩放，不能转
    Object.assign(this.controls, { enableDamping: true, dampingFactor: .08, screenSpacePanning: true, zoomToCursor: true, minDistance: 120, maxDistance: 5200, enableRotate: false });
    this.controls.mouseButtons = { LEFT: THREE.MOUSE.PAN, MIDDLE: THREE.MOUSE.DOLLY, RIGHT: THREE.MOUSE.PAN };
    this.controls.touches = { ONE: THREE.TOUCH.PAN, TWO: THREE.TOUCH.DOLLY_PAN };
    this.controls.addEventListener('start', () => { this.pausedUntil = performance.now() + 25000; this.tween = null; this.setCallout(null); });

    this.glowTex = this.makeGlow();
    this.starTex = this.makeStar();
    this.dotTex = this.makeDot();
    this.decor();
    this.banks = Object.fromEntries(Object.keys(LINE).map(k => [k, new Bank(this.scene, k)]));
    this.lit = this.makeLit();
    this.hot = this.makeHot();
    this.cards = new Map();
    this.makeCards();
    for (const c of this.cards.values()) c.draw();   // 一打开就有字，不黑一下
    this.dash = new Dash(this.data);
    this.bindUi();
    this.resize();
    this.overview(true);
    addEventListener('resize', () => this.resize());
    setInterval(() => this.slow(), 250);
    setInterval(() => this.dash.tickSecond(), 2000);
    this.loop = this.loop.bind(this);
    requestAnimationFrame(this.loop);
  }

  // MARK: 主程序来的消息（同世界）
  receive(msg) {
    if (!msg || !msg.type) return;
    switch (msg.type) {
      case 'init':
        setStrings(msg.lang, msg.strings);
        document.documentElement.lang = msg.lang === 'en' ? 'en' : 'zh-CN';
        this.mediaBase = msg.mediaBase || this.mediaBase || '';
        $('flow-door').hidden = !msg.door;
        if (msg.quality === 'medium' || msg.quality === 'low') { this.pixelRatio = Math.min(this.pixelRatio, msg.quality === 'low' ? 1.25 : 1.6); this.renderer.setPixelRatio(this.pixelRatio); this.resize(); }
        this.setInsets(msg.insets || {});
        this.relabel();
        break;
      case 'state': this.onState(msg.state || msg); break;
      case 'entries': this.onEntries(msg.key, msg.items, true); break;
      case 'usage': this.data.usage = msg; this.dash.dirty = true; break;
      case 'active': this.active = msg.active !== false; this.visible = msg.visible !== false; break;
      case 'insets': this.setInsets(msg); break;
      case 'focus': if (msg.key && this.cards.has('s:' + msg.key)) this.shoot(this.cards.get('s:' + msg.key)); break;
    }
  }

  setInsets(m) {
    const r = document.documentElement.style;
    for (const k of ['top', 'left', 'right', 'bottom']) if (typeof m[k] === 'number') r.setProperty('--inset-' + k, m[k] + 'px');
    requestAnimationFrame(() => this.resize());
  }

  onState(state) {
    const first = !this.data.order.length;
    const changed = this.data.applyState(state);
    if (changed || first) this.layoutSessions();
    for (const c of this.cards.values()) c.dirty = true;
    if (first && this.data.order.length) this.backfill();
  }

  onEntries(key, items, live) {
    const evs = this.data.applyEntries(key, items, { live });
    for (const ev of evs) this.fire(ev, live);
  }

  /// 补每个会话最近的调用（打开时一次）：一打开线就是满的
  async backfill() {
    if (!this.mediaBase && !this.mediaSuffix) return;
    const keys = this.data.order.slice(0, MAXS);
    const all = [];
    await Promise.all(keys.map(async (key) => {
      try {
        const r = await fetch(`${this.mediaBase}api/history?key=${encodeURIComponent(key)}&limit=80${this.mediaSuffix || ''}`);
        if (!r.ok) return;
        const body = await r.json();
        all.push([key, body.items || []]);
      } catch { /* 机器离线等：跳过 */ }
    }));
    const evs = [];
    for (const [key, items] of all) for (const ev of this.data.applyEntries(key, items, { live: false })) evs.push(ev);
    evs.sort((a, b) => a.ts - b.ts);
    for (const ev of evs.slice(-900)) this.fire(ev, false);
  }

  // MARK: 卡片
  makeCards() {
    const G = () => this.data.G, add = (id, def) => this.cards.set(id, new Card(this, { id, ...def }));
    add('brief', { x: 14, y: 34, w: 190, color: COLORS.teal, title: t('你的要求'), sub: 'user_brief', rowsN: 4, rows: () => [
      R(t('发来的话'), G().userMsgs, pct(G().userMsgs, 30)), R(t('等你确认'), G().asks, pct(G().asks, 10), { warn: G().asks > 0 }),
      R(t('平均字数'), G().userMsgs ? Math.round(G().userChars / G().userMsgs) : 0, pct(G().userChars / Math.max(1, G().userMsgs), 300)),
      { l: G().lastUser ? '「' + G().lastUser.slice(0, 24) + '」' : '—', wide: 1 }] });
    add('repo', { x: 14, y: 150, w: 190, color: COLORS.green, title: t('项目文件'), sub: 'repo_map', rowsN: 6, rows: () => {
      const tp = top(G().dirsRead, 6), mx = tp.length ? tp[0][1] : 1;
      return tp.length ? tp.map(([d, n]) => R(d, n, n / mx)) : [R('—', 0, 0)]; } });
    add('mem', { x: 14, y: 314, w: 190, color: COLORS.green, title: t('记忆'), sub: 'memory', rowsN: 3, rows: () => [
      R(t('条目'), G().memFiles.size, pct(G().memFiles.size, 40)), R(t('读取'), G().memReads, pct(G().memReads, 80)), { l: [...G().memFiles].slice(-1)[0] || '—', wide: 1 }] });
    add('web', { x: 14, y: 434, w: 190, color: COLORS.yellow, title: t('网页'), sub: 'web', rowsN: 3, rows: () => [
      R(t('抓取网页'), G().webFetch, pct(G().webFetch, 30)), R(t('搜索'), G().webSearch, pct(G().webSearch, 30)), { l: G().lastHost || '—', wide: 1 }] });
    add('cmdout', { x: 14, y: 554, w: 190, color: COLORS.yellow, title: t('命令输出'), sub: 'tool_results', rowsN: 4, rows: () => [
      R(t('命令'), G().cmds, pct(G().cmds, 600)), R(t('输出行'), G().outLines, pct(G().outLines, 4000)),
      R(t('报错'), G().errs, pct(G().errs, 60), { warn: 1 }), { l: G().lastCmd || '—', wide: 1 }] });
    add('model', { x: 900, y: 22, w: 200, color: COLORS.violet, title: this.modelName(), sub: 'plan', rowsN: 5, rows: () => {
      const ss = [...this.data.sessions.values()], ctx = ss.reduce((a, s) => a + s.context, 0), cache = cacheRatio(ss), tot = this.data.usage?.totals || {};
      return [R(t('思考'), t('%@ 次', G().thinks), pct(G().thinks, 400)), R(t('今日输出'), fmtTok(tot.output || 0), pct(tot.output || 0, 3e6)),
        R(t('缓存命中'), cache === null ? '—' : Math.round(cache * 100) + '%', cache || 0), R(t('上下文合计'), fmtTok(ctx), pct(ctx, 4e6)),
        R(t('思考用时'), Math.round(G().thinkSecs) + 's', pct(G().thinkSecs, 3000))]; } });
    add('explore', { x: 900, y: 160, w: 200, color: COLORS.orange, title: t('探索'), sub: 'explore', rowsN: 4, rows: () => [
      R(t('读文件'), G().by.read || 0, pct(G().by.read, 300)), R(t('搜代码'), G().by.grep || 0, pct(G().by.grep, 150)),
      R(t('网页'), (G().by.web || 0) + (G().by.search || 0), pct((G().by.web || 0) + (G().by.search || 0), 50)), R(t('读到行'), G().readLines, pct(G().readLines, 6000))] });
    add('edit', { x: 900, y: 296, w: 200, color: COLORS.orange, title: t('编辑'), sub: 'edit', rowsN: 4, rows: () => [
      R(t('改'), G().by.edit || 0, pct(G().by.edit, 200)), R(t('写新文件'), G().by.write || 0, pct(G().by.write, 80)),
      R(t('加行'), '+' + G().adds, pct(G().adds, 1500), { good: 1 }), R(t('删行'), '−' + G().dels, pct(G().dels, 800), { warn: 1 })] });
    add('run', { x: 900, y: 432, w: 200, color: COLORS.orange, title: t('运行 · 测试'), sub: 'run', rowsN: 4, rows: () => [
      R(t('命令'), G().by.run || 0, pct(G().by.run, 800)), R(t('测试'), G().by.test || 0, pct(G().by.test, 200)),
      R(t('构建'), G().by.build || 0, pct(G().by.build, 200)), R('Git', G().by.git || 0, pct(G().by.git, 40))] });
    add('collab', { x: 900, y: 568, w: 200, color: COLORS.blue, title: t('协作'), sub: 'subagent · remote', rowsN: 4, rows: () => [
      R(t('远程电脑'), G().by.ssh || 0, pct(G().by.ssh, 600)), R(t('汇报'), G().by.report || 0, pct(G().by.report, 200)),
      R(t('发消息'), G().by.msg || 0, pct(G().by.msg, 200)), R(t('子 agent'), G().by.agent || 0, pct(G().by.agent, 20))] });
    add('worktree', { x: 1214, y: 22, w: 210, color: COLORS.teal, title: t('改动文件'), sub: 'worktree/', rowsN: 6, rows: () => {
      const tp = top(G().filesEdited, 6), mx = tp.length ? tp[0][1] : 1;
      return tp.length ? tp.map(([f, n]) => R(f, n, n / mx)) : [R('—', 0, 0)]; } });
    add('checks', { x: 1214, y: 190, w: 210, color: COLORS.green, title: t('检查结果'), sub: 'out.checks', rowsN: 4, rows: () => {
      const all = G().testPass + G().testFail;
      return [R(t('测试通过'), G().testPass, pct(G().testPass, all), { good: 1 }), R(t('测试失败'), G().testFail, pct(G().testFail, all), { warn: 1 }),
        R(t('构建'), G().builds, pct(G().builds - G().buildFail, G().builds)), R(t('通过率'), all ? Math.round(G().testPass / all * 100) + '%' : '—', pct(G().testPass, all))]; } });
    add('commit', { x: 1214, y: 330, w: 210, color: COLORS.teal, title: t('提交 · 推送'), sub: 'merge', rowsN: 3, rows: () => [
      R(t('Git 提交'), G().commits, pct(G().commits, 20)), R(t('Git 推送'), G().pushes, pct(G().pushes, 20)), R(t('Git 操作'), G().by.git || 0, pct(G().by.git, 40))] });
    add('send', { x: 1214, y: 452, w: 210, color: COLORS.violet, title: t('发出去'), sub: 'out.send', rowsN: 4, rows: () => [
      R(t('你的手机'), G().by.report || 0, pct(G().by.report, 200)), R(t('别的会话'), G().by.msg || 0, pct(G().by.msg, 200)),
      R(t('远程电脑'), G().by.ssh || 0, pct(G().by.ssh, 600)), R(t('等你确认'), G().asks, pct(G().asks, 10), { warn: 1 })] });
    add('plan', { x: 1214, y: 588, w: 210, color: COLORS.yellow, title: t('计划进度'), sub: 'out.plan', rowsN: 4, rows: () => {
      let done = 0, all = 0, going = 0;
      for (const s of this.data.sessions.values()) if (s.stage) { all += s.stage.total; done += s.stage.step - 1; going++; }
      const busy = [...this.data.sessions.values()].filter(s => s.activity === 'busy').length;
      return [R(t('步骤'), `${done}/${all}`, pct(done, all)), R(t('进行中的任务'), going, pct(going, Math.max(1, this.data.sessions.size))),
        R(t('在工作的会话'), busy, pct(busy, Math.max(1, this.data.sessions.size)), { good: 1 }), R(t('上下文压缩'), G().compacts, pct(G().compacts, 20))]; } });
  }

  modelName() {
    const m = [...this.data.sessions.values()].map(s => s.model).find(Boolean) || 'claude';
    return m;
  }

  /// 中间那列：一个会话一张卡；多了只留标题条，再多就把最后一张变成「其余 N 个会话」
  layoutSessions() {
    for (const [id, c] of this.cards) if (id.startsWith('s:')) { c.dispose(); this.cards.delete(id); }
    const all = this.data.order, more = all.length > MAXS ? all.slice(MAXS - 1) : [];
    const keys = more.length ? all.slice(0, MAXS - 1) : all, n = Math.max(1, keys.length + (more.length ? 1 : 0));
    const step = Math.min(64, (DH - 24) / n), compact = step < 58;
    // 会话来自不止一台电脑：卡片标题旁写上是哪台（同名会话分得清）
    const multi = new Set(keys.map(k => this.data.sessions.get(k)?.source || '')).size > 1;
    keys.forEach((key, i) => {
      const s = this.data.sessions.get(key);
      const card = new Card(this, { id: 's:' + key, x: SES_X, y: 14 + i * step, w: SES_W, color: COLORS.pink, title: s.title, sub: multi ? s.source : '', rowsN: compact ? 0 : 2,
        rows: () => {
          const st = s.stage;
          return [R(st ? `${st.step}/${st.total} ${t(st.label || '')}` : s.activity === 'waiting' ? t('等你确认') : s.activity === 'busy' ? t('工作中') : t('空闲'),
            t('%@/分', this.data.rate(s)), st ? (st.step - .5) / st.total : s.activity === 'busy' ? .4 : 0),
          { l: s.last ? sayOf(s.last) : (s.activityText || '—'), wide: 1 }];
        } });
      card.live = true;
      card.isIdle = () => !this.data.live(s);
      card.em = () => s.context ? fmtTok(s.context) : '';
      card.key = key;
      card.kind = 'ses';
      this.cards.set('s:' + key, card);
    });
    if (more.length) {
      const card = new Card(this, { id: 's:@more', x: SES_X, y: 14 + keys.length * step, w: SES_W, color: '#8a6a80', title: t('其余 %@ 个会话', more.length), rowsN: compact ? 0 : 2,
        rows: () => {
          const ss = more.map(k => this.data.sessions.get(k)).filter(Boolean), busy = ss.filter(s => s.activity === 'busy').length;
          return [R(t('%@ 个在工作', busy), '', busy / Math.max(1, ss.length)), { l: ss.map(s => s.title).slice(0, 3).join(' · '), wide: 1 }];
        } });
      card.kind = 'ses'; card.more = new Set(more);
      this.cards.set('s:@more', card);
    }
    // 刚加入的会话：卡片亮两三秒
    for (const key of this.data.added || []) { const c = this.cards.get('s:' + key) || this.cards.get('s:@more'); if (c) c.heat = 3; }
    this.sesStep = step; this.compact = compact;
    // 新卡片的画布是空的，当场画上；等 slow() 的话整列会黑一下（有新会话加入时最明显）
    for (const c of this.cards.values()) if (c.kind === 'ses') c.draw();
    this.redrawLines();
  }

  relabel() {
    // 换了语言：卡片标题重新取一遍
    const names = { brief: '你的要求', repo: '项目文件', mem: '记忆', web: '网页', cmdout: '命令输出', explore: '探索', edit: '编辑', run: '运行 · 测试', collab: '协作', worktree: '改动文件', checks: '检查结果', commit: '提交 · 推送', send: '发出去', plan: '计划进度' };
    for (const [id, n] of Object.entries(names)) { const c = this.cards.get(id); if (c) { c.title = t(n); c.dirty = true; } }
    const lab = { 'flow-auto-l': '自动运镜', 'flow-home-l': '全景', 'flow-door-l': '离开' };
    for (const [id, n] of Object.entries(lab)) { const el = $(id); if (el) el.textContent = t(n); }
    const dash = { 'fd-thought-t': t('思考流'), 'fd-lanes-t': t('工具通道'), 'fd-core-t': t('模型核心'), 'fd-matrix-t': t('检查矩阵') };
    for (const [id, text] of Object.entries(dash)) { const el = $(id); if (el) el.textContent = text; }
  }

  // MARK: 一次调用 → 一串线
  route(ev, rand) {
    const c = this.cards, segs = [];
    const ses = c.get('s:' + ev.key) || c.get('s:@more');
    if (!ses) return segs;
    const sy = ses.rowY(0) + (this.compact ? 0 : 2) + (rand() - .5) * (this.compact ? 6 : 12);
    const src = this.srcOf(ev);
    const lift = (k) => LINE[k].lift[0] + rand() * (LINE[k].lift[1] - LINE[k].lift[0]);
    if (src) {
      const card = c.get(src[0]), p = card.right(src[1]);
      const by = Math.max(16, Math.min(DH - 10, p[1] + (rand() - .5) * 440));
      segs.push({ kind: 'hair', cards: [src[0], ses.id], pts: curve(p, [BUS_X, by], [p[0] + 30 + rand() * 120, p[1] + (rand() - .5) * 60], [BUS_X - 20 - rand() * 90, by + (rand() - .5) * 100], lift('hair'), D / 2) });
      segs.push({ kind: 'pink', cards: [src[0], ses.id], pts: curve([BUS_X, by], [SES_X, sy], [BUS_X + 110 + rand() * 130, by], [SES_X - 110 - rand() * 110, sy], lift('pink'), D / 2) });
    }
    const act = this.actOf(ev);
    let actCard = null, ay = 0;
    if (act) {
      actCard = c.get(act[0]);
      const q = actCard.left(act[1]); ay = q[1];
      segs.push({ kind: 'yel', cards: [ses.id, act[0]], pts: curve([SES_X + SES_W, sy], q, [SES_X + SES_W + 50 + rand() * 80, sy], [q[0] - 50 - rand() * 80, q[1] + (rand() - .5) * 8], lift('yel'), D / 2) });
    }
    const out = this.outOf(ev);
    if (out && actCard) {
      const q = c.get(out[0]).left(out[1]), p = [actCard.x + actCard.w, ay];
      segs.push({ kind: 'teal', cards: [act[0], out[0], ses.id], pts: curve(p, q, [p[0] + 40 + rand() * 60, p[1]], [q[0] - 40 - rand() * 60, q[1] + (rand() - .5) * 6], lift('teal'), D / 2) });
    }
    return segs;
  }

  srcOf(ev) {
    const G = this.data.G, p = ev.w[0] || ev.r[0];
    if (ev.k === 'user') return ['brief', 0];
    if (ev.k === 'ask') return ['brief', 1];
    if (['read', 'grep', 'edit', 'write'].includes(ev.k) || (ev.r.length && ev.code?.cmd)) {
      if (/\/memory\/|CLAUDE\.md|MEMORY\.md/.test(p || '')) return ['mem', 1];
      const d = (p || '').split('/').filter(Boolean), dir = d[0] === '~' ? '~' : d.length > 1 ? d[0] : t('（根目录）');
      const i = top(G.dirsRead, 6).findIndex(([x]) => x === dir);
      return ['repo', i < 0 ? 5 : i];
    }
    if (ev.k === 'web') return ['web', 0];
    if (ev.k === 'search') return ['web', 1];
    return ['cmdout', ev.err ? 2 : ev.code?.cmd ? 0 : 1];
  }
  actOf(ev) {
    return { read: ['explore', 0], grep: ['explore', 1], web: ['explore', 2], search: ['explore', 2], edit: ['edit', 0], write: ['edit', 1],
      run: ['run', 0], test: ['run', 1], build: ['run', 2], git: ['run', 3], skill: ['run', 0],
      ssh: ['collab', 0], report: ['collab', 1], msg: ['collab', 2], agent: ['collab', 3], user: ['model', 0], ask: ['model', 2] }[ev.k] || null;
  }
  outOf(ev) {
    if (ev.k === 'edit' || ev.k === 'write') { const i = top(this.data.G.filesEdited, 6).findIndex(([f]) => f === baseName(ev.w[0])); return ['worktree', i < 0 ? 5 : i]; }
    if (ev.k === 'test') return ['checks', ev.err ? 1 : 0];
    if (ev.k === 'build') return ['checks', 2];
    if (ev.k === 'git') return ['commit', ev.push ? 1 : 0];
    if (ev.k === 'report') return ev.stage ? ['plan', 0] : ['send', 0];
    if (ev.k === 'msg') return ['send', 1];
    if (ev.k === 'ssh') return ['send', 2];
    if (ev.k === 'ask') return ['send', 3];
    return null;
  }

  fire(ev, animate) {
    ev.seed = ev.seed || (this.events.length * 2654435761 + Math.round(ev.ts * 1000)) >>> 0;
    this.events.push(ev); if (this.events.length > 1800) this.events.splice(0, 300);
    const segs = this.route(ev, rng(ev.seed));
    ev.cards = new Set(segs.flatMap(sg => sg.cards));
    for (const s of segs) { this.banks[s.kind].add(s.pts, s.cards); for (const id of s.cards) { const cd = this.cards.get(id); if (cd) cd.dirty = true; } }
    // 只重画这次调用经过的卡（数字只在经过它的调用里变）+ 模型卡；以前每次把右边 15 张全标脏，会话卡片排不上、新会话一直是黑的
    this.cards.get('model').dirty = true;
    if (this.focusId && segs.some(s => s.cards.includes(this.focusId))) for (const b of Object.values(this.banks)) b.focus(this.focusId);
    if (!animate || !segs.length) return;
    this.dash.event(ev);
    for (const s of segs) for (const id of s.cards) this.cards.get(id)?.fires.push(performance.now());
    this.burst(ev, segs);
  }

  /// 一次调用放出一串光点（11-02：光点多一点，有数据时大量出现）：
  /// 沿这次调用自己那串线走 1 颗星芒领头 + 一串小光点（前后错开、快慢不一），
  /// 再在同一会话的线束里挑几根各走几颗，整束线都在流动；没数据时不放
  burst(ev, segs) {
    const now = performance.now();
    const n = 10 + Math.floor(Math.random() * 10) + (ev.k === 'edit' || ev.k === 'write' ? 6 : 0);
    this.spawn(segs, now, 1, true);
    for (let k = 1; k <= n; k++) this.spawn(segs, now + k * (35 + Math.random() * 55), .8 + Math.random() * .45, false);
    // 这串线：光点到之前亮起来，最后一颗走过去再慢慢退
    segs.forEach((sg, i) => this.light(sg.pts, sg.kind, now + i * SEG_MS / 1.25 - 120, now + (i + 1) * SEG_MS / .8 + n * 90, 1));
    const ses = 's:' + ev.key;
    for (const [kind, per] of [['pink', 3], ['yel', 3], ['hair', 2], ['teal', 2]]) {
      const bank = this.banks[kind], mine = [];
      for (let i = 0; i < bank.count; i++) if (bank.owner[i]?.includes(ses)) mine.push(i);
      for (let j = 0; j < Math.min(3, mine.length); j++) {
        const pts = bank.pointsOf(mine[Math.floor(Math.random() * mine.length)]), t0 = now + 150 + Math.random() * 900;
        for (let k = 0; k < per; k++) this.spawn([{ kind, pts, cards: [] }], t0 + k * 120, .7 + Math.random() * .5, false);
        this.light(pts, kind, t0 - 120, t0 + per * 120 + SEG_MS / .7, .7);
      }
    }
  }

  spawn(segs, t0, speed, lead) {
    if (this.parts.length >= MAXP) return;
    this.parts.push({ segs, t0, speed, lead, size: lead ? 52 : 26 + Math.random() * 14, hit: 0, dim: 1 });
  }

  /// 没调用时的慢光点（11-02）：只走在正在工作 / 等你确认的会话的线上，静默的会话一颗都不放；全都歇着时整块屏是静的
  ambient(now) {
    if (now - (this.ambientAt || 0) < 260) return;
    this.ambientAt = now;
    const active = [...this.data.sessions.values()].filter(s => s.activity === 'busy' || s.activity === 'waiting').map(s => 's:' + s.key);
    if (!active.length) return;
    const target = Math.min(this.w < 640 ? 18 : 34, active.length * 8);
    let alive = 0;
    for (const p of this.parts) if (p.amb) alive++;
    if (alive >= target || this.parts.length >= MAXP) return;
    const pick = [];
    for (const bank of Object.values(this.banks)) for (let i = 0; i < bank.count; i++) {
      const own = bank.owner[i];
      if (own && active.some(id => own.includes(id))) pick.push([bank, i]);
    }
    if (!pick.length) return;
    const [bank, i] = pick[Math.floor(Math.random() * pick.length)], speed = .16 + Math.random() * .16, pts = bank.pointsOf(i);
    this.parts.push({ segs: [{ kind: bank.kind, pts, cards: [] }], t0: now, speed, lead: false, size: 20 + Math.random() * 10, hit: 0, dim: .6, amb: true });
    this.light(pts, bank.kind, now, now + SEG_MS / speed, .45);
  }

  // MARK: 点亮有光点的那根线：另一组加法混合的线，只放正亮着的几百根，亮度随时间起落
  makeLit() {
    const n = LITN * SEG * 2, geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.BufferAttribute(new Float32Array(n * 3), 3).setUsage(THREE.DynamicDrawUsage));
    geo.setAttribute('color', new THREE.BufferAttribute(new Float32Array(n * 3), 3).setUsage(THREE.DynamicDrawUsage));
    const obj = new THREE.LineSegments(geo, new THREE.LineBasicMaterial({ vertexColors: true, transparent: true, blending: THREE.AdditiveBlending, depthWrite: false }));
    obj.frustumCulled = false;
    this.scene.add(obj);
    this.litSlots = new Array(LITN).fill(null);
    this.hotLine = Object.fromEntries(Object.entries(LINE).map(([k, v]) => [k, new THREE.Color(v.hot)]));
    return obj;
  }

  light(pts, kind, start, end, strength) {
    let i = this.litSlots.indexOf(null);
    if (i < 0) { let oldest = 0; this.litSlots.forEach((sl, k) => { if (sl.end < this.litSlots[oldest].end) oldest = k; }); i = oldest; }
    this.litSlots[i] = { start, end, strength, col: this.hotLine[kind] };
    const P = this.lit.geometry.attributes.position, o = i * SEG * 2 * 3;
    for (let k = 0; k < SEG; k++) { const a = pts[k], b = pts[k + 1]; P.array.set([a.x, a.y, a.z + .3, b.x, b.y, b.z + .3], o + k * 6); }
    P.needsUpdate = true;
  }

  tickLit(now) {
    const C = this.lit.geometry.attributes.color;
    let any = false;
    for (let i = 0; i < LITN; i++) {
      const sl = this.litSlots[i];
      if (!sl) continue;
      const rise = Math.max(0, Math.min(1, (now - sl.start) / 220)), fall = now > sl.end ? Math.max(0, 1 - (now - sl.end) / 1000) : 1;
      const f = rise * fall * sl.strength * .55, o = i * SEG * 2 * 3;
      for (let k = 0; k < SEG * 2; k++) { C.array[o + k * 3] = sl.col.r * f; C.array[o + k * 3 + 1] = sl.col.g * f; C.array[o + k * 3 + 2] = sl.col.b * f; }
      if (now > sl.end + 1000) this.litSlots[i] = null;
      any = true;
    }
    if (any || this.litWas) C.needsUpdate = true;
    this.litWas = any;
  }

  redrawLines() {
    for (const b of Object.values(this.banks)) b.clear();
    const keep = this.events.slice(-1500);
    for (const ev of keep) for (const s of this.route(ev, rng(ev.seed))) this.banks[s.kind].add(s.pts, s.cards);
    if (this.focusId) for (const b of Object.values(this.banks)) b.focus(this.focusId);
  }

  // MARK: 光点：一组 Points（领头的是星芒，其余是小圆点），只在调用发生时沿线走
  makeHot() {
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.BufferAttribute(new Float32Array(MAXP * 3), 3).setUsage(THREE.DynamicDrawUsage));
    g.setAttribute('color', new THREE.BufferAttribute(new Float32Array(MAXP * 3), 3).setUsage(THREE.DynamicDrawUsage));
    g.setAttribute('size', new THREE.BufferAttribute(new Float32Array(MAXP), 1).setUsage(THREE.DynamicDrawUsage));
    g.setAttribute('star', new THREE.BufferAttribute(new Float32Array(MAXP), 1).setUsage(THREE.DynamicDrawUsage));
    g.setDrawRange(0, 0);
    const pts = new THREE.Points(g, new THREE.ShaderMaterial({
      uniforms: { starMap: { value: this.starTex }, dotMap: { value: this.dotTex }, scale: { value: 1 } },
      vertexShader: 'attribute float size; attribute float star; attribute vec3 color; uniform float scale; varying vec3 vColor; varying float vStar;'
        + 'void main(){ vColor = color; vStar = star; vec4 mv = modelViewMatrix * vec4(position,1.0); gl_PointSize = size * scale / -mv.z; gl_Position = projectionMatrix * mv; }',
      fragmentShader: 'uniform sampler2D starMap; uniform sampler2D dotMap; varying vec3 vColor; varying float vStar;'
        + 'void main(){ vec4 d = texture2D(dotMap, gl_PointCoord); float a = mix(d.a, texture2D(starMap, gl_PointCoord).a, vStar);'
        + ' vec3 c = mix(vColor, vec3(1.0), max(d.r * .85, vStar * .55)); gl_FragColor = vec4(c * 1.25, a); }',
      transparent: true, blending: THREE.AdditiveBlending, depthWrite: false,
    }));
    pts.frustumCulled = false;
    this.scene.add(pts);
    this.parts = [];
    this.hotColor = Object.fromEntries(Object.entries(LINE).map(([k, v]) => [k, new THREE.Color(v.hot)]));
    return { stars: pts };
  }

  tickGlints(now) {
    const geo = this.hot.stars.geometry, P = geo.attributes.position.array, C = geo.attributes.color.array, S = geo.attributes.size.array, ST = geo.attributes.star.array;
    let n = 0;
    for (let i = this.parts.length - 1; i >= 0; i--) {
      const p = this.parts[i];
      if (now < p.t0) continue;
      const el = (now - p.t0) / SEG_MS * p.speed, total = p.segs.length;
      if (el >= total) { this.parts[i] = this.parts[this.parts.length - 1]; this.parts.pop(); continue; }
      const k = Math.floor(el), u = el - k, seg = p.segs[k];
      // 领头的星芒到了哪张卡，那张卡亮一下
      if (p.lead && k >= p.hit) { p.hit = k + 1; for (const id of seg.cards) { const c = this.cards.get(id); if (c) c.heat = 1; } }
      const q = sample(seg.pts, u * SEG), col = this.hotColor[seg.kind];
      // 起步淡入、走到头淡出（慢慢冒出来的那些淡入得更慢）
      const fade = Math.min(1, el * (p.amb ? 2.5 : 6), (total - el) * 3);
      P[n * 3] = q.x; P[n * 3 + 1] = q.y; P[n * 3 + 2] = q.z + 1;
      const f = fade * p.dim;
      C[n * 3] = col.r * f; C[n * 3 + 1] = col.g * f; C[n * 3 + 2] = col.b * f;
      S[n] = p.lead ? p.size + 14 * Math.sin(now / 70 + i) : p.size * (.9 + .1 * Math.sin(now / 120 + i));
      ST[n] = p.lead ? 1 : 0;
      n++;
    }
    geo.setDrawRange(0, n);
    for (const a of ['position', 'color', 'size', 'star']) geo.attributes[a].needsUpdate = true;
  }

  // MARK: 镜头：全景、对准一张卡（自动运镜）
  overviewPose() {
    const fov = this.camera.fov * Math.PI / 180, a = this.camera.aspect;
    const dist = Math.max((DH * 1.06 / 2) / Math.tan(fov / 2), (DW * 1.04 / 2) / (Math.tan(fov / 2) * a));
    const phone = this.w < 640;
    // 竖着的手机：全景太小，默认看中间的会话列那一块
    if (phone && a < 1) return { pos: new THREE.Vector3(-20, 0, dist * .42), target: new THREE.Vector3(-20, 0, 0) };
    return { pos: new THREE.Vector3(0, 0, dist), target: new THREE.Vector3(0, 0, 0) };
  }
  overview(now) {
    const p = this.overviewPose();
    this.setCallout(null);
    this.flyTo(p.pos, p.target, now ? 0 : 2200);
    this.title(null);
  }
  shoot(card) {
    // 2D：正对着平移、放大到这张卡，画面里留出旁边的卡和连过来的线（不倾斜、不旋转）
    const half = Math.tan(this.camera.fov * Math.PI / 360), a = this.camera.aspect;
    const wantW = a < 1 ? card.w * 1.7 : Math.max(560, Math.min(900, card.w * 3.2));
    const r = Math.max(wantW / (2 * half * a), (card.h * 2.4) / (2 * half));
    const target = card.center.clone().setZ(0).add(new THREE.Vector3(card.kind === 'ses' ? -40 : 0, 0, 0));
    const pos = target.clone().add(new THREE.Vector3(0, 0, r));
    this.flyTo(pos, target, 2400);
    this.shots++;
    this.focus(card.id);
    this.shotCard = card;
    this.title(card);
    setTimeout(() => { if (this.shotCard === card) this.setCallout(card); }, 1600);
  }
  flyTo(pos, target, ms) {
    if (!ms) { this.camera.position.copy(pos); this.controls.target.copy(target); this.controls.update(); this.tween = null; return; }
    this.tween = { p0: this.camera.position.clone(), t0: this.controls.target.clone(), p1: pos, t1: target, s: performance.now(), ms };
  }
  focus(id) {
    if (this.focusId === id) return;
    this.focusId = id;
    for (const b of Object.values(this.banks)) b.focus(id);
  }

  /// 自动运镜：挑最近最忙的一张卡飞过去、停一会儿，每三下回一次全景
  direct(now) {
    if (!this.auto || now < this.pausedUntil || this.picked) return;
    if (this.nextShot && now < this.nextShot) return;
    let busy = [...this.cards.values()].map(c => [c, c.score(now) * (c.kind === 'ses' ? 1.3 : 1)]).filter(([, s]) => s > 0).sort((a, b) => b[1] - a[1]);
    // 这会儿没人在干活：轮流看连线最多的几张卡，画面别停
    if (!busy.length) busy = [...this.cards.values()].map(c => [c, this.lineCount(c.id)]).filter(([, n]) => n > 0).sort((a, b) => b[1] - a[1]).slice(0, 8);
    const recent = this.recentShots || (this.recentShots = []);
    const pick = busy.find(([c]) => !recent.includes(c.id));
    if (this.shots % 3 === 2 || !pick) {
      this.shots++;
      this.shotCard = null; this.focus(null);
      this.overview(false);
      this.nextShot = now + 6500;
      return;
    }
    recent.push(pick[0].id); if (recent.length > 3) recent.shift();
    this.shoot(pick[0]);
    this.nextShot = now + 7200;
  }

  title(card) {
    const box = $('flow-title');
    const live = [...this.data.sessions.values()].filter(s => this.data.live(s)).length;
    let num = String(live).padStart(2, '0'), name = t('%@ 个会话在跑', live), sub = t('共 %@ 个会话 · %@ 次调用', this.data.sessions.size, this.data.G.calls);
    if (card) {
      const G = this.data.G, n = (this.shots % 99) + 1;
      num = String(n).padStart(2, '0');
      const PH = { brief: '你的要求', repo: '加载上下文', mem: '读取记忆', web: '查网页', cmdout: '命令输出回流', model: '模型在想', explore: '探索代码', edit: '改动落地',
        run: '跑命令和测试', collab: '协作与汇报', worktree: '写出的文件', checks: G.testFail ? '测试变红' : '测试通过', commit: '提交推送', send: '发给你和别的会话', plan: '计划推进' };
      if (card.kind === 'ses') {
        const s = this.data.sessions.get(card.key);
        name = s ? s.title : card.title;
        sub = s?.stage ? t('第 %@ 步，共 %@ 步 · %@', s.stage.step, s.stage.total, t(s.stage.label || '')) : (s?.last ? sayOf(s.last) : '');
      } else {
        name = t(PH[card.id] || card.title);
        // 第二行写最近经过这张卡的那次调用：做了什么、对象、哪个会话
        const last = this.recentFor(card, 1)[0];
        sub = last ? `${this.itemText(last)} · ${this.data.sessions.get(last.key)?.title || ''}` : '';
      }
    }
    box.innerHTML = `<b>${esc(num)}</b><div><span>${esc(name)}</span><small>${esc(sub)}</small></div>`;
  }
  lineCount(id) { return Object.values(this.banks).reduce((a, b) => a + b.countOf(id), 0); }

  /// 最近经过这张卡的调用（会话卡片 = 这个会话自己的），新的在前
  recentFor(card, n) {
    const out = [];
    for (let i = this.events.length - 1; i >= 0 && out.length < n; i--) {
      const ev = this.events[i];
      if (card.more ? card.more.has(ev.key) : card.kind === 'ses' ? ev.key === card.key : ev.cards?.has(card.id)) out.push(ev);
    }
    return out;
  }
  /// 一次调用说成一句：读 orders.ts / 改 Price.tsx / 命令 npm test / 你说 …
  itemText(ev) {
    const p = ev.w[0] || ev.r[0];
    const what = ev.k === 'user' || ev.k === 'ask' ? ev.label : p && !ev.code?.cmd ? baseName(p) : ev.label || (p ? baseName(p) : '');
    return `${t(VERB[ev.k] || '命令')} ${what}`;
  }

  /// 对准一张卡时旁边的标注（11-02：不写多少根线，写这些线对应的具体内容）：最近经过它的几次调用——做了什么、对象、哪个会话
  setCallout(card) {
    const el = $('flow-callout');
    this.calloutCard = card;
    if (!card) { el.hidden = true; return; }
    el.hidden = false;
    el.style.setProperty('--c', card.color);
    const items = this.recentFor(card, this.w < 640 ? 4 : 6);
    this.calloutSig = items.map(e => e.toolId || e.ts).join('|');
    const rows = items.map(ev => {
      const p = ev.w[0] || ev.r[0], what = ev.k === 'user' || ev.k === 'ask' ? ev.label : p && !ev.code?.cmd ? baseName(p) : ev.label || (p ? baseName(p) : '');
      const who = card.kind === 'ses' && !card.more ? '' : `<em>${esc(this.data.sessions.get(ev.key)?.title || '')}</em>`;
      return `<li><i style="color:${kindColor(ev)}">${esc(t(VERB[ev.k] || '命令'))}</i><span>${esc(what)}</span>${who}</li>`;
    }).join('');
    const open = card.kind === 'ses' && !card.more ? `<button id="flow-open">${esc(t('打开会话'))}</button>` : '';
    el.innerHTML = `<b>${esc(card.kind === 'ses' ? card.title : card.title + ' · ' + card.sub)}</b>` +
      (rows ? `<ul>${rows}</ul>` : `<span>${esc(t('还没有调用经过这里'))}</span>`) + open;
    $('flow-open')?.addEventListener('click', (e) => { e.stopPropagation(); host.post({ type: 'open', key: card.key }); });
  }

  placeCallout() {
    const card = this.calloutCard, el = $('flow-callout');
    if (!card || el.hidden) return;
    const p = W(card.x + card.w, card.y + card.h, D).project(this.camera);
    const x = (p.x * .5 + .5) * this.w, y = (-p.y * .5 + .5) * this.h;
    const cw = el.offsetWidth || 200, ch = el.offsetHeight || 60;
    el.style.transform = `translate(${Math.round(Math.min(this.w - cw - 8, Math.max(8, x + 8)))}px, ${Math.round(Math.min(this.h - ch - 8, Math.max(8, y + 6)))}px)`;
  }

  // MARK: 界面
  bindUi() {
    const autoBtn = $('flow-auto');
    const syncAuto = () => autoBtn.classList.toggle('on', this.auto);
    syncAuto();
    autoBtn.addEventListener('click', () => { this.auto = !this.auto; try { localStorage.setItem('flow.auto', this.auto ? '1' : '0'); } catch { /* 存不了 */ } syncAuto(); this.pausedUntil = 0; this.nextShot = 0; if (!this.auto) { this.focus(null); this.setCallout(null); } });
    $('flow-home').addEventListener('click', () => { this.picked = null; this.focus(null); this.overview(false); this.pausedUntil = performance.now() + 20000; });
    $('flow-door').addEventListener('click', () => host.post({ type: 'exit' }));
    // 点卡片：只亮它的线（会话卡片旁边给「打开会话」）；点空白处恢复。拖动不算点
    let down = null;
    this.canvas.addEventListener('pointerdown', (e) => { down = [e.clientX, e.clientY]; });
    this.canvas.addEventListener('click', (e) => {
      if (down && Math.hypot(e.clientX - down[0], e.clientY - down[1]) > 6) return;
      const r = this.canvas.getBoundingClientRect(), ray = new THREE.Raycaster();
      ray.setFromCamera(new THREE.Vector2((e.clientX - r.left) / r.width * 2 - 1, -(e.clientY - r.top) / r.height * 2 + 1), this.camera);
      const hit = ray.intersectObjects([...this.cards.values()].map(c => c.mesh))[0];
      const card = hit?.object.userData.card || null;
      if (!card || this.picked === card) { this.picked = null; this.focus(null); this.setCallout(null); this.title(null); return; }
      this.picked = card; this.focus(card.id); this.setCallout(card); this.title(card);
      this.pausedUntil = performance.now() + 30000;
    });
    this.canvas.addEventListener('dblclick', () => { this.picked = null; this.focus(null); this.overview(false); });
  }

  resize() {
    const box = this.canvas.parentElement.getBoundingClientRect();
    this.w = Math.max(1, box.width); this.h = Math.max(1, box.height);
    this.renderer.setSize(this.w, this.h, false);
    this.camera.aspect = this.w / this.h; this.camera.updateProjectionMatrix();
    this.hot.stars.material.uniforms.scale.value = this.h * this.pixelRatio * .9;
    this.dash.resize();
    if (!this.tween && !this.picked && !this.shotCard) this.overview(true);
  }

  // MARK: 背景：暗红的大星形、竖总线
  decor() {
    const g = new THREE.Group();
    // 总线：一列小点 + 一根虚线 + 刻度
    const dots = [], ticks = document.createElement('canvas'), s = 3;
    ticks.width = 40 * s; ticks.height = DH * s;
    const tg = ticks.getContext('2d'); tg.scale(s, s); tg.font = `7px ${MONO}`; tg.fillStyle = '#5d6476';
    for (let y = 18, i = 0; y < DH - 6; y += 20, i++) { dots.push(W(BUS_X, y, 1)); if (i % 2 === 0) tg.fillText(String(i).padStart(2, '0'), 6, y + 2.5); }
    g.add(new THREE.Points(new THREE.BufferGeometry().setFromPoints(dots), new THREE.PointsMaterial({ color: 0x7d93c9, size: 3, sizeAttenuation: false })));
    const bus = new THREE.Line(new THREE.BufferGeometry().setFromPoints([W(BUS_X, 10, .5), W(BUS_X, DH - 6, .5)]), new THREE.LineDashedMaterial({ color: 0x5a6a90, dashSize: 2, gapSize: 3 }));
    bus.computeLineDistances();
    g.add(bus);
    const tt = new THREE.CanvasTexture(ticks); tt.colorSpace = THREE.SRGBColorSpace;
    const plane = new THREE.Mesh(new THREE.PlaneGeometry(40, DH), new THREE.MeshBasicMaterial({ map: tt, transparent: true, depthWrite: false }));
    plane.position.copy(W(BUS_X + 20, DH / 2, .5));
    g.add(plane);
    this.scene.add(g);
    this.grid = this.makeGrid();
  }

  /// 背景是一张带格子的画布（11-02）：20 一小格、100 一大格，对齐设计坐标；
  /// 着色器按屏幕像素画线，怎么缩放线都是 1 像素细，拉远了小格慢慢隐去只留大格。平面跟着镜头走，拖到哪都铺满
  makeGrid() {
    const mat = new THREE.ShaderMaterial({
      uniforms: {
        uBg: { value: new THREE.Color('#06070b') }, uMinor: { value: new THREE.Color('#11141c') }, uMajor: { value: new THREE.Color('#1a1e2a') },
        uOrigin: { value: new THREE.Vector2(-DW / 2, DH / 2) }, uCell: { value: 20 }, uPx: { value: this.pixelRatio },
      },
      vertexShader: `varying vec2 vP;
        void main() { vec4 w = modelMatrix * vec4(position, 1.0); vP = w.xy; gl_Position = projectionMatrix * viewMatrix * w; }`,
      fragmentShader: `uniform vec3 uBg; uniform vec3 uMinor; uniform vec3 uMajor; uniform vec2 uOrigin; uniform float uCell; uniform float uPx;
        varying vec2 vP;
        float line(vec2 p, float cell) {
          vec2 c = p / cell, d = fwidth(c);
          vec2 g = abs(fract(c - 0.5) - 0.5) / d / uPx;
          return 1.0 - min(min(g.x, g.y), 1.0);
        }
        void main() {
          vec2 p = vP - uOrigin;
          float px = uCell / max(fwidth(p.x), 1e-4) / uPx;
          vec3 c = mix(uBg, uMinor, line(p, uCell) * smoothstep(5.0, 14.0, px));
          c = mix(c, uMajor, line(p, uCell * 5.0));
          gl_FragColor = vec4(c, 1.0);
          #include <colorspace_fragment>
        }`,
      depthWrite: false,
    });
    const m = new THREE.Mesh(new THREE.PlaneGeometry(1, 1), mat);
    m.position.z = -8; m.renderOrder = -1; m.frustumCulled = false;
    this.scene.add(m);
    return m;
  }
  /// 画布平面挪到镜头正下方、按看到的范围放大（每帧）
  fitGrid() {
    const h = 2 * Math.tan(this.camera.fov * Math.PI / 360) * (this.camera.position.z + 8) * 1.3;
    this.grid.position.x = this.camera.position.x; this.grid.position.y = this.camera.position.y;
    this.grid.scale.set(h * Math.max(1, this.camera.aspect), h, 1);
    this.grid.material.uniforms.uPx.value = this.pixelRatio;
  }

  makeGlow() {
    const c = document.createElement('canvas'); c.width = c.height = 128;
    const g = c.getContext('2d'), gr = g.createRadialGradient(64, 64, 20, 64, 64, 64);
    gr.addColorStop(0, 'rgba(255,255,255,.55)'); gr.addColorStop(1, 'rgba(255,255,255,0)'); g.fillStyle = gr; g.fillRect(0, 0, 128, 128);
    return new THREE.CanvasTexture(c);
  }
  /// 发光的光点（11-02：光点要发光）：alpha 是外面一圈柔光，red 通道是中间那颗亮芯
  makeDot() {
    const N = 64, data = new Uint8Array(N * N * 4);
    for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) {
      const d = Math.hypot(x + .5 - N / 2, y + .5 - N / 2) / (N / 2);
      const halo = Math.max(0, Math.exp(-d * d * 7) * (1 - d));
      const core = Math.max(0, 1 - d / .18);
      const o = (y * N + x) * 4;
      data[o] = Math.round(Math.min(1, core) * 255); data[o + 1] = 0; data[o + 2] = 0;
      data[o + 3] = Math.round(Math.min(1, halo + core) * 255);
    }
    const t = new THREE.DataTexture(data, N, N);
    t.needsUpdate = true;
    t.magFilter = THREE.LinearFilter; t.minFilter = THREE.LinearFilter;
    return t;
  }
  makeStar() {
    const c = document.createElement('canvas'); c.width = c.height = 64;
    const g = c.getContext('2d'), gr = g.createRadialGradient(32, 32, 0, 32, 32, 32);
    gr.addColorStop(0, 'rgba(255,255,255,1)'); gr.addColorStop(.15, 'rgba(255,255,255,.75)'); gr.addColorStop(.45, 'rgba(255,255,255,.22)'); gr.addColorStop(1, 'rgba(255,255,255,0)');
    g.fillStyle = gr; g.fillRect(0, 0, 64, 64);
    g.fillStyle = '#fff'; g.beginPath(); g.moveTo(32, 2); g.lineTo(35, 29); g.lineTo(62, 32); g.lineTo(35, 35); g.lineTo(32, 62); g.lineTo(29, 35); g.lineTo(2, 32); g.lineTo(29, 29); g.closePath(); g.fill();
    return new THREE.CanvasTexture(c);
  }

  // MARK: 慢的：卡片重画、顶部遥测
  slow() {
    if (!this.visible) return;
    for (const c of this.cards.values()) if (c.dirty) c.draw();
    const cm = this.cards.get('model'); if (cm) { const m = this.modelName(); if (m !== cm.title) { cm.title = m; cm.dirty = true; } }
    const ss = [...this.data.sessions.values()], live = ss.filter(s => this.data.live(s)).length, G = this.data.G, tot = this.data.usage?.totals || {};
    const ctx = ss.reduce((a, s) => a + s.context, 0);
    const it = (k, v, opt) => `<span class="${opt ? 'opt' : ''}"><i>${esc(k)}</i>${esc(v)}</span>`;
    $('flow-hud-l').innerHTML = `<span class="brand">KITELINE</span><b>${esc(this.modelName())}</b>` + it(t('会话'), `${live}/${ss.length}`) + it(t('改动行'), G.adds + G.dels) +
      it(t('上下文合计'), fmtTok(ctx), 1) + it(t('工具调用'), G.calls) + it(t('今日 token'), fmtTok((tot.input || 0) + (tot.output || 0) + (tot.cacheRead || 0) + (tot.cacheWrite || 0)), 1) +
      it(t('今日请求'), tot.requests || 0, 1) + it('TICK', String(G.calls % 10000).padStart(4, '0'), 1);
    if (!this.shotCard && !this.picked) this.title(null);
    if (this.calloutCard) {
      const sig = this.recentFor(this.calloutCard, this.w < 640 ? 4 : 6).map(e => e.toolId || e.ts).join('|');
      if (sig !== this.calloutSig) { this.setCallout(this.calloutCard); this.title(this.calloutCard); }
    }
  }

  loop(now) {
    requestAnimationFrame(this.loop);
    if (!this.visible) return;
    if (!this.active && now - (this.lastFrame || 0) < 80) return;
    this.lastFrame = now;
    this.direct(now);
    if (this.tween) {
      const u = Math.min(1, (now - this.tween.s) / this.tween.ms), e = ease(u);
      this.camera.position.lerpVectors(this.tween.p0, this.tween.p1, e);
      this.controls.target.lerpVectors(this.tween.t0, this.tween.t1, e);
      if (u >= 1) this.tween = null;
    } else if (this.auto && now > this.pausedUntil && this.shotCard) {
      // 停在一张卡前时镜头慢慢推近一点、往右挪一点（2D 的推拉摇移），画面不死
      this.camera.position.z -= this.camera.position.z * .00025;
      this.camera.position.x += .05; this.controls.target.x += .05;
    }
    this.controls.update();
    for (const c of this.cards.values()) {
      if (c.heat > 0) c.heat = Math.max(0, c.heat - .02);
      const want = Math.max(c.heat * .9, this.focusId === c.id ? .55 : 0);
      if (Math.abs(c.glow.material.opacity - want) > .005) c.glow.material.opacity = want;
    }
    this.ambient(now);
    this.tickGlints(now);
    this.tickLit(now);
    this.fitGrid();
    this.renderer.render(this.scene, this.camera);
    this.placeCallout();
    this.dash.draw(now);
    this.frames = (this.frames || 0) + 1;
  }
}

function sample(pts, f) {
  const i = Math.max(0, Math.min(SEG - 1, Math.floor(f))), u = Math.max(0, Math.min(1, f - i));
  return pts[i].clone().lerp(pts[i + 1], u);
}

const flow = new Flow();
window.World = { receive: (msg) => flow.receive(typeof msg === 'string' ? JSON.parse(msg) : msg), flow };
window.chrome?.webview?.addEventListener('message', (e) => flow.receive(e.data));
const params = new URLSearchParams(location.search);
try {
  if (params.has('t')) {
    sessionStorage.setItem('world.t', params.get('t'));
    const rest = new URLSearchParams(params); rest.delete('t');
    history.replaceState(null, '', location.pathname + (rest.toString() ? '?' + rest : '') + location.hash);
  } else if (sessionStorage.getItem('world.t')) params.set('t', sessionStorage.getItem('world.t'));
} catch { /* 存不了就留在地址里 */ }
if (params.has('t')) {
  // 直连模式（Windows / Linux）：同世界，自己连接口；补历史时带令牌
  import('./api.js').then(({ startApi }) => startApi(flow, params));
} else {
  host.post({ type: 'ready' });
  if (!host.connected || params.has('demo')) import('./flowdemo.js').then(({ startDemo }) => startDemo(flow));
}
// 自测：帧率和线数
setInterval(() => { document.body.dataset.stats = JSON.stringify({ fps: flow.frames || 0, events: flow.events.length, dots: flow.parts.length, sessions: flow.data.sessions.size }); flow.frames = 0; }, 1000);
