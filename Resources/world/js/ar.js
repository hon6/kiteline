// AR 模式：窗口透明铺满屏幕，能直接看到桌面；所有会话（和它们在用的浏览器）是漂在空中的窗口，在你面前排成一面略带弧度的墙，按项目分组。
// 你站在原点：WASD 走动、Q/E 升降、拖动（或按住右键）转头、滚轮前后、触控板横扫转身；指着一个窗口它会飞到你面前放大，移开就回去；
// 点一下镜头运过去，窗口展开成完整对话、能直接回复和确认；有新消息、等你确认的窗口隔一会儿抖一下，转到背后的会在屏幕边上标出方向。
// 宿主：Mac 的 WorldHost（AR 窗口里那一份），协议同 world.md（内部文档） 第 9 节，另加 browser_frame / cmd / prefs，页面发 press / browser / viewed / rects / prefs。

import * as THREE from '../vendor/three.module.min.js';
import { CSS3DRenderer } from '../vendor/addons/renderers/CSS3DRenderer.js';
import { SessionPanel, BrowserTile, GroupLabel, PW, PH, projectOf, statusOf, esc } from './arpanel.js';
import { setStrings, t } from './i18n.js';
import { Backdrop, BACKDROPS } from './arbg.js';

const GX = 30, GY = 28, GROUP_GAP = 96;     // 窗口之间、组之间的空隙（场景单位）
const REST_SCALE = [0.74, 0.9];               // 平时窗口看起来是原尺寸的多少（字 14px → 10.4～12.6px）
const HOVER_SCALE = 0.97;                     // 指着时放到多大（接近 1:1，字最清楚）
const HOVER_W = 640, HOVER_H = 500;           // 指着时窗口本身放大到多大
const FOCUS_LIFT = 150;                       // 打开的窗口往前挪一点，和邻居分开
const PING_EVERY = 3200;                      // 有消息的窗口隔多久抖一次（每次抖 1 秒，像 QQ 窗口抖动）

const host = {
  connected: !!(window.webkit?.messageHandlers?.world || window.chrome?.webview),
  post(msg) {
    try {
      if (window.webkit?.messageHandlers?.world) window.webkit.messageHandlers.world.postMessage(msg);
      else if (window.chrome?.webview) window.chrome.webview.postMessage(msg);
    } catch { /* 没有宿主：演示 */ }
  },
};
const $ = (id) => document.getElementById(id);
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
const damp = (k, dt) => 1 - Math.exp(-k * dt);
const wrapAngle = (a) => { while (a > Math.PI) a -= 2 * Math.PI; while (a < -Math.PI) a += 2 * Math.PI; return a; };

class AR {
  constructor() {
    this.sessions = new Map();
    this.panels = new Map();       // 窗口 id（会话 key，或 b:<key> 浏览器）→ 窗口
    this.labels = new Map();       // 项目名 → 名牌
    this.groupOrder = [];          // 项目先后（第一次排的顺序，之后新项目接在后面）
    this.layoutMode = 'arc';
    this.passthrough = false;
    this.follow = false;
    this.fullscreen = false;
    this.background = 'none';     // none 透明 / space / sky / sea / forest / aurora / video（宿主在下面放用户自己的视频或图片）       // 默认只铺在软件窗口那一块（宿主在 init / prefs 里告诉）
    this.mediaBase = ''; this.mediaSuffix = '';
    this.marks = {};
    this.visible = true;
    this.keys = new Set();
    this.mouse = { x: innerWidth / 2, y: innerHeight / 2, inside: false };
    this.look = null;              // 正在拖动转头
    this.hovered = null; this.hoverWant = null; this.hoverTimer = 0;
    this.focused = null; this.saved = null;
    this.peeked = null; this.peekUntil = 0; this.lastInput = performance.now();
    this.edgeSince = 0;
    this.lastPing = 0;
    this.dirty = true;

    // 镜头：目标值 + 平滑后的当前值（运镜就是让当前值追目标）
    this.cam = { pos: new THREE.Vector3(), yaw: 0, pitch: 0 };
    this.cur = { pos: new THREE.Vector3(), yaw: 0, pitch: 0 };
    this.para = { yaw: 0, pitch: 0 };
    this.flying = 0;               // 运镜中：追得慢一点、像镜头运动
    this.fly = 7;

    this.scene = new THREE.Scene();
    this.camera = new THREE.PerspectiveCamera(48, innerWidth / innerHeight, 1, 30000);
    this.camera.rotation.order = 'YXZ';
    this.renderer = new CSS3DRenderer();
    $('ar-stage').appendChild(this.renderer.domElement);
    this.renderer.domElement.className = 'ar-world';
    this.dummy = new THREE.Object3D();

    this.backdrop = new Backdrop($('ar-bg'), this);
    this.bind();
    this.resize();
    addEventListener('resize', () => { this.resize(); this.layout(); if (this.focused?.el.classList.contains('under')) this.postDetail(); });
    this.hint(true);
    this.clock();
    setInterval(() => this.clock(), 15000);
    this.last = performance.now();
    requestAnimationFrame((now) => this.frame(now));
  }

  post(msg) { host.post(msg); }

  // MARK: 宿主发来的
  receive(msg) {
    if (!msg || !msg.type) return;
    switch (msg.type) {
      case 'init':
        setStrings(msg.lang, msg.strings || {});
        if (msg.brand) document.documentElement.style.setProperty('--brand', msg.brand);
        this.marks = msg.marks || this.marks;
        if (msg.mediaBase) this.mediaBase = msg.mediaBase;
        // iPad：触摸操作、背后是摄像头画面（宿主在下面放），转动设备 = 转头（陀螺仪，宿主发 pose）
        if (msg.touch) { this.touch = true; document.body.classList.add('touch'); }
        if (msg.prefs) this.applyPrefs(msg.prefs);
        $('ar-door').hidden = !msg.door;
        this.localize();
        break;
      case 'state': this.onState(msg.state || {}); break;
      case 'entries': this.onEntries(msg.key, msg.items || []); break;
      case 'browser_frame': this.panels.get('b:' + msg.key)?.frame(msg); break;
      case 'focus': { const p = this.panels.get(msg.key); if (p) this.focus(p); break; }
      case 'sent': this.toast(msg.ok === false ? t('发送失败，请稍后重试') : t('已发送')); break;
      case 'active': this.visible = msg.visible !== false; if (this.visible) { this.last = performance.now(); this.dirty = true; } this.watchBrowsers(); break;
      case 'prefs': this.applyPrefs(msg); break;
      case 'cmd': this.command(msg.name); break;
      case 'pose': this.onPose(msg); break;
      case 'dictation': this.onDictation(msg); break;
      case 'insets': break;
    }
  }

  applyPrefs(p) {
    if (p.layout && p.layout !== this.layoutMode) { this.layoutMode = p.layout; this.layout(); }
    if (typeof p.passthrough === 'boolean') {
      this.passthrough = p.passthrough;
      document.body.classList.toggle('pass', p.passthrough);
      this.rectSig = '';
    }
    if (typeof p.follow === 'boolean') this.follow = p.follow;
    if (typeof p.gyro === 'boolean') { this.gyro = p.gyro; this.poseLast = null; this.poseF = null; }
    if (typeof p.background === 'string') this.background = p.background;
    // 穿透时要看得见桌面：背景先藏起来
    this.backdrop.set(this.passthrough ? 'none' : this.background);
    if (typeof p.fullscreen === 'boolean') { this.fullscreen = p.fullscreen; document.body.classList.toggle('windowed', !p.fullscreen); }
    this.hudButtons();
  }

  command(name) {
    switch (name) {
      case 'home': this.home(); break;
      case 'next': this.nextAttention(); break;
      case 'layout': this.cycleLayout(); break;
      case 'hint': this.hint(); break;
      case 'unfocus': this.unfocus(); break;
    }
  }

  /// 窗口里「按住 说话」：按下开始录（宿主的听写），松开转成文字直接发给这个会话；滑走 / 被打断就不发
  talkStart(key, button) {
    if (this.talk) return;
    this.talk = { key, button, cancel: false };
    button.classList.add('on');
    button.textContent = t('松开 发送');
    this.post({ type: 'dictate', action: 'start' });
  }

  talkStop(cancel) {
    const talk = this.talk;
    if (!talk || talk.stopping) return;
    talk.stopping = true;
    talk.cancel = cancel;
    talk.button.classList.remove('on');
    talk.button.textContent = cancel ? t('按住 说话') : t('正在识别…');
    this.post({ type: 'dictate', action: cancel ? 'cancel' : 'stop' });
  }

  onDictation(m) {
    const talk = this.talk;
    if (!talk) return;
    if (m.state === 'recording' || m.state === 'level' || m.state === 'converting') return;
    this.talk = null;
    talk.button.classList.remove('on');
    talk.button.textContent = t('按住 说话');
    if (m.state === 'failed') { this.toast(m.text || t('录音未能开始，请重试')); return; }
    const text = (m.text || '').trim();
    if (talk.cancel) return;
    if (!text) { this.toast(m.note || t('未能识别，请重新说一遍')); return; }
    this.send(talk.key, text);
  }

  /// 陀螺仪（iPad）：宿主每帧发设备朝向（yaw 水平转角、pitch 俯仰，弧度、绝对值），这里只取变化量加到镜头上，
  /// 和手指拖动叠加（拖过之后再转设备，接着拖过的方向转）
  onPose(m) {
    if (!this.gyro || typeof m.yaw !== 'number') return;
    // 防抖（11-22：手机、iPad 抖得厉害）：① 读数先低通平滑；② 手抖这种很小的变化（约 0.15°）不算，攒够了才动；
    // ③ 只改镜头目标，由每帧的阻尼慢慢追上（不再直接改当前值，那样每一点抖动都原样上屏）
    // 设备往前推 / 往后拉（ARKit 测的位移，米，沿镜头方向）= 往前走 / 往后退：低通后 1 厘米以下的晃动不算
    // 只认明显的推拉（约每秒 25 厘米以上）：慢慢的漂移（镜头看不清东西时 ARKit 会漂，平放在桌上实测 2 秒漂 0.4 米，
    // 镜头一路飘走、窗口全不见了）不算；手机平放 / 对着天花板（俯仰超过约 65°）时也不算
    if (typeof m.push === 'number' && !this.focused && Math.abs(m.pitch) < 1.15) {
      this.pushF = (this.pushF || 0) * 0.4 + m.push * 0.6;
      // 胳膊伸直 / 收回约 20 厘米 ≈ 走近 / 退开 1800 单位（窗口离你约 2000）：放大缩小要一眼看得出、跟手（11-22 反馈：不明显、再灵敏些）
      if (Math.abs(this.pushF) > 0.0035) {
        this.cam.pos.addScaledVector(this.forward(), clamp(this.pushF * 9000, -280, 280));
        this.dirty = true;
      }
    }
    const f = this.poseF;
    if (!f) { this.poseF = { yaw: m.yaw, pitch: m.pitch }; this.poseLast = { yaw: m.yaw, pitch: m.pitch }; return; }
    f.yaw += wrapAngle(m.yaw - f.yaw) * 0.22;
    f.pitch += (m.pitch - f.pitch) * 0.22;
    const last = this.poseLast;
    const dy = wrapAngle(f.yaw - last.yaw), dp = f.pitch - last.pitch;
    if (Math.abs(dy) < 0.0026 && Math.abs(dp) < 0.0026) return;
    this.poseLast = { yaw: f.yaw, pitch: f.pitch };
    if (this.focused) return;
    this.cam.yaw += dy;
    this.cam.pitch = clamp(this.cam.pitch + dp, -1.15, 1.15);
    this.lastInput = performance.now();
    this.dirty = true;
  }

  localize() {
    $('ar-door').textContent = t('离开');
    this.hintHTML = this.touch ? [
      [t('转动设备'), t('环顾四周')], [t('往前推 / 往后拉'), t('放大 / 缩小')], [t('单指拖动'), t('转向')], [t('双指捏合'), t('前后')], [t('轻点窗口'), t('打开')],
      [t('双击空白处'), t('复位')],
    ].map(([k, v]) => `<span><kbd>${esc(k)}</kbd>${esc(v)}</span>`).join('') : [
      ['WASD', t('移动')], ['Q / E', t('升降')], [t('拖动空白处'), t('转向')], [t('滚轮'), t('前后')], [t('悬停'), t('放大')],
      [t('点击'), t('打开')], ['Tab', t('下一个待处理')], ['B', t('换背景')], ['M', t('全屏')], ['Esc', t('返回')],
    ].map(([k, v]) => `<span><kbd>${esc(k)}</kbd>${esc(v)}</span>`).join('');
    $('ar-hint').innerHTML = this.hintHTML;
    this.hudButtons();
    this.stats();
  }

  // MARK: 数据
  onState(state) {
    const list = Array.isArray(state.sessions) ? state.sessions : [];
    const first = !this.sessions.size && list.length;
    const keys = new Set();
    for (const s of list) {
      if (!s || !s.key) continue;
      keys.add(s.key);
      this.sessions.set(s.key, s);
    }
    for (const key of [...this.sessions.keys()]) if (!keys.has(key)) this.sessions.delete(key);
    // 该有哪些窗口：每个会话一块；用着浏览器（没关）的再挂一块
    const want = new Set();
    for (const s of this.sessions.values()) {
      want.add(s.key);
      if (s.browser && !s.browser.closed && (s.browser.url || s.browser.since)) want.add('b:' + s.key);
    }
    let changed = false;
    for (const id of want) {
      if (this.panels.has(id)) continue;
      const key = id.startsWith('b:') ? id.slice(2) : id;
      const p = id.startsWith('b:') ? new BrowserTile(this, key) : new SessionPanel(this, key);
      this.panels.set(id, p);
      this.scene.add(p.obj);
      p.fresh = true;
      changed = true;
      if (!id.startsWith('b:') && !first) this.loadHistory(p);
    }
    for (const [id, p] of [...this.panels]) {
      if (want.has(id)) continue;
      if (this.focused === p) this.unfocus(true);
      if (this.hovered === p) this.hovered = null;
      this.scene.remove(p.obj);
      p.dispose();
      this.panels.delete(id);
      if (id.startsWith('b:')) this.post({ type: 'browser', key: p.key, level: 'off' });
      changed = true;
    }
    for (const p of this.panels.values()) {
      const s = this.sessions.get(p.key);
      if (s) p.setSession(s);
      if (p.fresh) { p.fresh = false; p.render?.(); }
    }
    if (changed) this.layout(); else this.applyDepth();
    if (first) this.backfill();
    this.watchBrowsers();
    this.stats();
    this.dirty = true;
  }

  onEntries(key, items) {
    const p = this.panels.get(key);
    if (!p) return;
    p.addItems(items);
    const reply = items.some(it => it && (it.t === 'text' || it.t === 'agent_image'));
    if (reply && p !== this.focused && p !== this.hovered) {
      p.unread = true;
      p.attn = true;
      p.el.classList.add('attn');
      p.ping();
      if (this.follow) this.peek(p);
      this.stats();
    }
    if (p === this.focused) p.seen();
  }

  /// 打开时补每个会话最近的对话（一打开窗口里就有内容）
  async backfill() {
    const list = [...this.panels.values()].filter(p => p instanceof SessionPanel);
    let i = 0;
    const next = async () => {
      while (i < list.length) await this.loadHistory(list[i++]);
    };
    await Promise.all([next(), next(), next(), next()]);
  }

  async loadHistory(p, limit = 40) {
    if (!this.mediaBase && !this.mediaSuffix) { p.loaded = true; p.render(); return; }
    try {
      const r = await fetch(`${this.mediaBase}api/history?key=${encodeURIComponent(p.key)}&limit=${limit}${this.mediaSuffix || ''}`);
      if (r.ok) p.addItems((await r.json()).items || []);
    } catch { /* 机器离线：等实时的 */ }
    p.loaded = true;
    const s = this.sessions.get(p.key);
    if (s) p.setSession(s);
    p.render();
    this.stats();
  }

  mediaUrl(key, ref) { return `${this.mediaBase}api/media?key=${encodeURIComponent(key)}&ref=${encodeURIComponent(ref)}${this.mediaSuffix || ''}`; }

  markSvg(agent) {
    const paths = this.marks[agent];
    if (!paths || !paths.length) return '';
    return `<svg viewBox="0 0 24 24">${paths.map(p => `<path d="${esc(p.d)}" fill="currentColor" opacity="${p.opacity ?? 1}"/>`).join('')}</svg>`;
  }

  send(key, text) {
    this.post({ type: 'send', key, text, images: [], id: Date.now().toString(36) });
    const p = this.panels.get(key);
    p?.addItems([{ id: 'local-' + Date.now(), t: 'user', text, ts: Date.now(), queued: true }]);
  }

  /// 浏览器画面：看得见的要小图（2 帧/秒），打开的那块要大图；看不见的退订
  watchBrowsers() {
    for (const p of this.panels.values()) {
      if (!(p instanceof BrowserTile)) continue;
      const level = !this.visible ? 'off' : p === this.focused || p === this.hovered ? 'full' : 'thumb';
      if (level !== p.level) { p.level = level; this.post({ type: 'browser', key: p.key, level }); }
    }
  }

  // MARK: 排版
  resize() {
    this.camera.aspect = innerWidth / innerHeight;
    this.camera.updateProjectionMatrix();
    this.renderer.setSize(innerWidth, innerHeight);
    // 离镜头 P 远、正对着的窗口在屏幕上正好 1:1（CSS3DRenderer 的透视距离）
    this.P = (innerHeight / 2) / Math.tan(THREE.MathUtils.degToRad(this.camera.fov / 2));
    this.dirty = true;
  }

  /// 墙：窗口排成几行，按项目分组（组里竖着填），最近活跃的项目在正前方，其余左右交替往外排；
  /// 弧形（默认）是一面微弯的墙；环绕是围着你一圈；平面是一整面平墙
  layout() {
    const ids = [...this.panels.keys()];
    const n = ids.length;
    // 组：项目名 → 窗口（会话按开始时间，浏览器紧跟在它的会话后面）
    const groups = new Map();
    const sessions = [...this.sessions.values()].sort((a, b) => (a.startedAt || a.updatedAt || 0) - (b.startedAt || b.updatedAt || 0));
    for (const s of sessions) {
      const g = projectOf(s);
      if (!groups.has(g)) groups.set(g, []);
      if (this.panels.has(s.key)) groups.get(g).push(this.panels.get(s.key));
      if (this.panels.has('b:' + s.key)) groups.get(g).push(this.panels.get('b:' + s.key));
    }
    // 项目先后：第一次按最近活跃排，之后新项目接在后面（不因为状态变化来回挪）
    if (!this.groupOrder.length) {
      const recent = (g) => Math.max(0, ...groups.get(g).map(p => this.sessions.get(p.key)?.updatedAt || 0));
      this.groupOrder = [...groups.keys()].sort((a, b) => recent(b) - recent(a));
    } else {
      for (const g of groups.keys()) if (!this.groupOrder.includes(g)) this.groupOrder.push(g);
    }
    const order = this.groupOrder.filter(g => groups.has(g) && groups.get(g).length);

    // 窗口多大、几行：先试大的，整面墙放不进视野就一档档缩小（字仍看得清：1 倍屏最小 0.74 ≈ 10px，视网膜屏 0.66 也清楚），
    // 最小还放不下就让它往两边延伸（转头看，边上有方向标）
    const vh = innerHeight;
    // 手机竖着（三四百宽）：平时窗口缩得更小，一屏多看几个；轻点打开时放大到屏幕宽
    const range = innerWidth < 600 ? [0.42, 0.56] : (devicePixelRatio || 1) >= 2 ? [0.66, 0.86] : REST_SCALE;
    const hfov = 2 * Math.atan(Math.tan(THREE.MathUtils.degToRad(this.camera.fov / 2)) * this.camera.aspect);
    let s, rows, D, k, widths, total, Ra;
    const measure = (scale, R) => {
      const d = this.P / scale;
      const w = order.map(g => Math.ceil(groups.get(g).length / R) * (PW + GX) - GX);
      return { d, w, total: w.reduce((a, b) => a + b, 0) + Math.max(0, order.length - 1) * GROUP_GAP };
    };
    // 从站的位置看过去整面墙占多大角度（墙微弯，按离你的距离算，偏保守）
    const fits = (m) => m.total / m.d <= hfov * 0.86;
    search: for (s = range[1]; ; s -= 0.02) {
      s = Math.max(s, range[0]);
      const most = clamp(Math.floor((vh * 0.84 + GY * s) / ((PH + GY) * s)), 1, 4);
      const least = n <= 3 ? 1 : Math.min(2, most);
      // 同样大小先试行少的；放不下再加一行；都放不下就再缩一档
      for (rows = least; rows <= most; rows++) {
        const m = measure(s, rows);
        if (fits(m) || this.layoutMode === 'ring' || (s <= range[0] && rows === most)) { D = m.d; widths = m.w; total = m.total; break search; }
      }
    }
    k = this.layoutMode === 'ring' ? 0 : this.layoutMode === 'flat' ? D * 14 : D * 0.9;
    Ra = D + k;
    if (this.layoutMode === 'ring' && total / Ra > Math.PI * 1.85) Ra = total / (Math.PI * 1.85);   // 一圈放不下就把圈放大
    const Dr = Ra - k;
    // 正中一组，后面的左右交替
    const spans = [];
    let left = 0, right = 0;
    order.forEach((g, i) => {
      const w = widths[i];
      if (i === 0) { spans[i] = -w / 2; left = -w / 2; right = w / 2; }
      else if (i % 2) { spans[i] = right + GROUP_GAP; right += GROUP_GAP + w; }
      else { spans[i] = left - GROUP_GAP - w; left -= GROUP_GAP + w; }
    });
    // 整面墙放得进视野时整体居中（各组宽窄不一时左右才对称）；放不下时保持最近活跃的那组在正前方
    const fov = 2 * Math.atan(Math.tan(THREE.MathUtils.degToRad(this.camera.fov / 2)) * this.camera.aspect);
    if ((right - left) / D < fov * 0.9 || this.layoutMode === 'ring') {
      const shift = (left + right) / 2;
      for (let i = 0; i < spans.length; i++) spans[i] -= shift;
    }
    const place = (obj, u, y, tilt = true) => {
      const beta = u / Ra;
      obj.pos = new THREE.Vector3(Ra * Math.sin(beta), y, k - Ra * Math.cos(beta));
      this.dummy.rotation.set(tilt ? Math.atan2(y, Dr) * 0.75 : 0, -beta, 0, 'YXZ');
      obj.quat = this.dummy.quaternion.clone();
      return obj;
    };
    const rowY = (r, R) => ((R - 1) / 2 - r) * (PH + GY);
    const seenLabels = new Set();
    order.forEach((g, gi) => {
      const items = groups.get(g);
      const R = Math.min(rows, items.length);
      items.forEach((p, i) => {
        const c = Math.floor(i / R), r = i % R;
        const u = spans[gi] + c * (PW + GX) + PW / 2;
        const was = p.rest;
        p.slot = { u, y: rowY(r, R) };
        p.rest = place({}, u, rowY(r, R));
        if (!was) {
          // 新窗口从远处、下方飘进来
          p.obj.position.copy(p.rest.pos).multiplyScalar(1.6).add(new THREE.Vector3(0, -260, 0));
          p.obj.quaternion.copy(p.rest.quat);
        }
      });
      // 项目名牌：在这组最上面一行的上方
      let label = this.labels.get(g);
      if (!label) { label = new GroupLabel(g); this.labels.set(g, label); this.scene.add(label.obj); }
      const busy = items.filter(p => p instanceof SessionPanel && p.status === 'busy').length;
      label.set(g, items.filter(p => p instanceof SessionPanel).length, busy);
      const top = rowY(0, R) + PH / 2 + 46;
      label.rest = place({}, spans[gi] + widths[gi] / 2, top);
      if (!label.placed) { label.obj.position.copy(label.rest.pos); label.obj.quaternion.copy(label.rest.quat); label.placed = true; }
      seenLabels.add(g);
    });
    for (const [g, label] of [...this.labels]) {
      if (seenLabels.has(g)) continue;
      this.scene.remove(label.obj); label.el.remove(); this.labels.delete(g);
    }
    this.D = Dr;
    this.geo = { Ra, k, Dr };
    this.applyDepth();
    this.dirty = true;
  }

  /// 深度层次：最近有动静的会话在最前面，越早的越往里退（同一个方向上往后推，看起来更小、更淡；各占各的位置，不互相挡）。
  /// 会话一有新动静就慢慢飘到前面来（11-21 用户要的）
  applyDepth() {
    if (!this.geo) return;
    const { Ra, k, Dr } = this.geo;
    const when = (p) => this.sessions.get(p.key)?.updatedAt || 0;
    const list = [...this.panels.values()].filter(p => p.slot).sort((a, b) => when(b) - when(a));
    const keys = [...new Set(list.map(p => p.key))];
    const span = Math.min(1500, Dr * 0.85);
    for (const p of list) {
      const rank = keys.indexOf(p.key), f = keys.length > 1 ? rank / (keys.length - 1) : 0;
      const R = Ra + f * span, beta = p.slot.u / Ra;
      p.rest = { pos: new THREE.Vector3(R * Math.sin(beta), p.slot.y, k - R * Math.cos(beta)), quat: p.rest.quat };
      p.el.style.setProperty('--fade', (f * 0.38).toFixed(3));
    }
    this.dirty = true;
  }

  cycleLayout() {
    const next = { arc: 'ring', ring: 'flat', flat: 'arc' }[this.layoutMode] || 'arc';
    this.layoutMode = next;
    this.layout();
    this.post({ type: 'prefs', layout: next });
    this.toast({ arc: t('弧形排列'), ring: t('环绕排列'), flat: t('平面排列') }[next]);
    this.hudButtons();
  }

  // MARK: 镜头
  home() {
    this.unfocus(true);
    this.cam.pos.set(0, 0, 0); this.cam.yaw = 0; this.cam.pitch = 0;
    this.flyTo();
  }

  flyTo(speed = 4.2) { this.flying = performance.now(); this.fly = speed; this.dirty = true; }

  /// 镜头看向某点（不动位置）
  lookAt(v) {
    const d = v.clone().sub(this.cam.pos).normalize();
    this.cam.pitch = Math.asin(clamp(d.y, -1, 1));
    const yaw = Math.atan2(-d.x, -d.z);
    this.cam.yaw = this.cur.yaw + wrapAngle(yaw - this.cur.yaw);
  }

  /// 点了一个窗口（或 Tab、侧栏、边上的方向标）：镜头转过去看它，它飘到眼前、放大、停住，直接在里面打字（11-21 反馈：不要再飞到中间弹一个会话页）
  focus(p) {
    if (!p || !p.rest) return;
    const ndc = p.rest.pos.clone().project(this.camera);
    if (Math.abs(ndc.x) > .8 || Math.abs(ndc.y) > .8 || ndc.z > 1) { this.lookAt(p.rest.pos); this.flyTo(4); }
    this.pin(p);
  }

  /// 选中一个窗口：保持悬停时那个放大的样子（没悬停着的先放大到那个样子），停住不动，光标进它自己的输入框直接打字
  /// （11-21 反馈：悬停放大的状态下点击直接输入，不要换成别的样子）。Esc / 点空白 / 按 WASD 放开
  pin(p) {
    if (this.pinned !== p) {
      this.pinned = null;
      if (this.hovered !== p) this.setHover(p);
      for (const q of this.panels.values()) q.el.classList.toggle('pinned', q === p);
      this.pinned = p;
      if (p instanceof SessionPanel) { p.seen(); if (!p.full) { p.full = true; this.loadHistory(p, 120); } }
      this.watchBrowsers();
      this.stats();
    }
    if (p instanceof SessionPanel && !p.voice && !p.input.disabled && document.activeElement !== p.input) p.input.focus({ preventScroll: true });
  }

  unpin() {
    const p = this.pinned;
    if (!p) return;
    this.pinned = null;
    p.el.classList.remove('pinned');
    if (p instanceof SessionPanel) p.input.blur();
    this.setHover(null);
    this.post({ type: 'typing', on: false });
  }

  /// 点了对话里的图：铺满窗口看大图，点一下或 Esc 关
  lightbox(src) {
    const box = $('ar-lightbox');
    box.querySelector('img').src = src;
    box.hidden = false;
  }

  /// 打开的窗口在屏幕上的位置（镜头正对着它、1:1，所以就是屏幕正中那一块）
  postDetail() {
    const p = this.focused;
    if (!p) return;
    this.post({ type: 'detail', key: p.key, rect: [Math.round((innerWidth - p.w) / 2), Math.round((innerHeight - p.h) / 2), p.w, p.h] });
  }

  unfocus(stay = false, quiet = false) {
    if (this.pinned) this.unpin();
    const p = this.focused;
    if (!p) return;
    this.focused = null;
    clearTimeout(this.detailTimer);
    if (p.el.classList.contains('under')) { p.el.classList.remove('under'); this.post({ type: 'detail', key: '' }); }
    p.el.classList.remove('focus');
    p.setSize(PW, PH);
    p.focusPos = null;
    if (p instanceof SessionPanel) { p.input.blur(); p.render(); }
    if (!quiet) {
      document.body.classList.remove('focusing');
      for (const q of this.panels.values()) q.el.classList.remove('dim');
      if (!stay && this.saved) {
        this.cam.pos.copy(this.saved.pos); this.cam.yaw = this.cur.yaw + wrapAngle(this.saved.yaw - this.cur.yaw); this.cam.pitch = this.saved.pitch;
        this.flyTo(3.6);
      }
      this.saved = null;
    }
    this.watchBrowsers();
    this.dirty = true;
  }

  /// 跟随：来了新消息的窗口飘到眼前停几秒（不抢正在用的）
  peek(p) {
    if (this.focused || this.look || performance.now() - this.lastInput < 6000) return;
    this.peeked = p;
    this.peekUntil = performance.now() + 5200;
    this.lookAt(p.rest.pos);
    this.flyTo(2.6);
  }

  /// Tab：下一个需要你的（先等确认的，再新消息），镜头运过去打开
  nextAttention(back = false) {
    const list = [...this.panels.values()].filter(p => p.attn && p.rest);
    if (!list.length) { this.toast(t('暂无待处理的会话')); return; }
    list.sort((a, b) => (b.status === 'waiting') - (a.status === 'waiting') || a.rest.pos.x - b.rest.pos.x);
    const i = list.indexOf(this.focused);
    const next = list[(i + (back ? -1 : 1) + list.length) % list.length];
    this.focus(next);
  }

  // MARK: 输入
  bind() {
    const stage = $('ar-stage');
    const isPanel = (e) => e.target.closest?.('.pn');
    stage.addEventListener('contextmenu', (e) => e.preventDefault());
    // 双指捏合（iPad）= 前后移动：两根手指都按着时不转头，按两指距离的变化往前 / 往后走
    const touches = new Map();
    const spread = () => { const [a, b] = [...touches.values()]; return Math.hypot(a.x - b.x, a.y - b.y); };
    stage.addEventListener('pointerdown', (e) => {
      if (e.pointerType === 'touch') {
        touches.set(e.pointerId, { x: e.clientX, y: e.clientY });
        if (touches.size === 2) {
          if (this.look) { stage.releasePointerCapture?.(this.look.id); this.look = null; document.body.classList.remove('looking'); }
          this.press = null;
          this.pinch = { d: spread() };
          e.preventDefault();
          return;
        }
      }
      this.lastInput = performance.now();
      const pn = isPanel(e);
      if (e.button === 2 || e.button === 1 || (e.button === 0 && !pn)) {
        // 左键拖空白处 = 抓着空间拖（内容跟着鼠标走）；按住右键 = 转头（鼠标往哪边，视线往哪边）
        this.look = { x: e.clientX, y: e.clientY, moved: 0, empty: !pn, id: e.pointerId, sign: e.button === 0 ? 1 : -1 };
        if (this.focused?.el.classList.contains('under') && e.button !== 0) this.unfocus(true);
        stage.setPointerCapture?.(e.pointerId);
        document.body.classList.add('looking');
        this.setHover(null);
        if (!pn || e.button !== 0) e.preventDefault();
      } else if (pn) {
        this.press = { id: pn.dataset.id, x: e.clientX, y: e.clientY };
      }
    });
    stage.addEventListener('pointermove', (e) => {
      if (touches.has(e.pointerId)) touches.set(e.pointerId, { x: e.clientX, y: e.clientY });
      if (this.pinch && touches.size === 2) {
        const d = spread();
        if (this.focused) this.unfocus(true);
        this.cam.pos.addScaledVector(this.forward(), clamp((d - this.pinch.d) * 4, -900, 900));
        this.pinch.d = d;
        this.flying = 0; this.lastInput = performance.now(); this.dirty = true;
        return;
      }
      if (e.pointerType === 'touch' && this.pinch) return;
      this.mouse.x = e.clientX; this.mouse.y = e.clientY; this.mouse.inside = true;
      if (this.look) {
        const dx = e.clientX - this.look.x, dy = e.clientY - this.look.y;
        this.look.x = e.clientX; this.look.y = e.clientY;
        this.look.moved += Math.abs(dx) + Math.abs(dy);
        if (this.look.moved > 6 && this.focused?.el.classList.contains('under')) this.unfocus(true);
        const k = 0.0042 * (this.camera.fov / 48);
        this.cam.yaw += dx * k * this.look.sign;
        this.cam.pitch = clamp(this.cam.pitch + dy * k * this.look.sign, -1.15, 1.15);
        this.flying = 0;
        this.dirty = true;
        return;
      }
      const pn = isPanel(e);
      this.wantHover(pn ? this.panels.get(pn.dataset.id) : null);
    });
    const end = (e) => {
      touches.delete(e.pointerId);
      if (this.pinch) { if (touches.size === 0) this.pinch = null; return; }
      if (this.look) {
        const click = this.look.moved < 5 && this.look.empty && e.button === 0;
        stage.releasePointerCapture?.(this.look.id);
        this.look = null;
        document.body.classList.remove('looking');
        if (click && this.pinned) this.unpin();
        if (click && this.focused) this.unfocus();
      } else if (this.press) {
        const moved = Math.abs(e.clientX - this.press.x) + Math.abs(e.clientY - this.press.y);
        const p = this.panels.get(this.press.id);
        this.press = null;
        const inControl = e.target.closest?.('button, textarea, input, a, .pn-opts');
        if (p && moved < 6 && !inControl && p !== this.pinned && !getSelection()?.toString()) this.pin(p);
      }
    };
    stage.addEventListener('pointerup', end);
    stage.addEventListener('pointercancel', end);
    stage.addEventListener('pointerleave', () => { this.mouse.inside = false; this.wantHover(null); });
    stage.addEventListener('dblclick', (e) => { if (!isPanel(e)) this.home(); });
    stage.addEventListener('wheel', (e) => {
      this.lastInput = performance.now();
      const pn = isPanel(e);
      // 指着 / 打开着的窗口：滚它自己的对话；空白处：前后移动，横扫转身；捏合 = 前后
      if (pn && !e.ctrlKey) {
        const p = this.panels.get(pn.dataset.id);
        if (p && (p === this.hovered || p === this.focused || e.target.closest('.pn-body'))) return;
      }
      e.preventDefault();
      if (this.focused && !pn) this.unfocus(true);
      const f = this.forward();
      const dz = (e.ctrlKey ? -e.deltaY * 6 : -e.deltaY * 2.2);
      this.cam.pos.addScaledVector(f, clamp(dz, -900, 900));
      if (!e.ctrlKey && Math.abs(e.deltaX) > Math.abs(e.deltaY) * 0.6) this.cam.yaw -= e.deltaX * 0.0022;
      this.flying = 0;
      this.dirty = true;
    }, { passive: false });

    addEventListener('keydown', (e) => {
      this.lastInput = performance.now();
      const typing = e.target.closest?.('textarea, input');
      if (e.key === 'Escape') {
        e.preventDefault();
        if (!$('ar-lightbox').hidden) { $('ar-lightbox').hidden = true; return; }
        if (this.pinned) { this.unpin(); return; }
        if (this.focused) this.unfocus();
        else if (this.hovered) this.setHover(null);
        else this.askExit();
        return;
      }
      if (typing || e.metaKey || e.ctrlKey || e.altKey) return;
      const k = e.key.toLowerCase();
      if ('wasdqe'.includes(k) && k.length === 1 || e.key.startsWith('Arrow') || e.key === 'Shift') {
        if (this.focused && 'wasdqe'.includes(k)) this.unfocus(true);
        if (this.pinned && 'wasdqe'.includes(k)) this.unpin();
        this.keys.add(e.key.startsWith('Arrow') ? e.key : k);
        this.flying = 0;
        e.preventDefault();
        return;
      }
      if (e.key === 'Tab') { e.preventDefault(); this.nextAttention(e.shiftKey); return; }
      if (k === 'r' || e.key === 'Home') { this.home(); return; }
      if (k === 'l') { this.cycleLayout(); return; }
      if (k === 'f') { this.follow = !this.follow; this.post({ type: 'prefs', follow: this.follow }); this.toast(this.follow ? t('跟随新消息：已打开') : t('跟随新消息：已关闭')); this.hudButtons(); return; }
      if (k === 'p') { this.post({ type: 'prefs', passthrough: !this.passthrough }); return; }
      if (k === 'b') { const list = BACKDROPS, i = list.indexOf(this.background); this.post({ type: 'prefs', background: list[(i + 1) % list.length] }); return; }
      if (k === 'm') { this.post({ type: 'prefs', fullscreen: !this.fullscreen }); return; }
      if (k === 'h' || e.key === '?') { this.hint(); return; }
      // 回车：打开着的窗口 → 光标进输入框；指着的窗口 → 打开它
      if (e.key === 'Enter' && this.pinned?.input && !this.pinned.input.disabled) { e.preventDefault(); this.pinned.input.focus({ preventScroll: true }); return; }
      if (e.key === 'Enter' && this.focused?.input && !this.focused.input.disabled) { e.preventDefault(); this.focused.input.focus({ preventScroll: true }); return; }
      if (e.key === 'Enter' && this.hovered) { this.focus(this.hovered); }
    });
    addEventListener('keyup', (e) => {
      this.keys.delete(e.key.startsWith('Arrow') ? e.key : e.key.toLowerCase());
      if (e.key === 'Shift') this.keys.delete('shift');
    });
    addEventListener('blur', () => this.keys.clear());
    $('ar-door').addEventListener('click', () => this.post({ type: 'exit' }));
    $('ar-lightbox').addEventListener('click', () => { $('ar-lightbox').hidden = true; });
    $('ar-tools').addEventListener('click', (e) => {
      const b = e.target.closest('button[data-cmd]');
      if (!b) return;
      const cmd = b.dataset.cmd;
      if (cmd === 'pass') this.post({ type: 'prefs', passthrough: !this.passthrough });
      else if (cmd === 'bg') { const list = BACKDROPS, i = list.indexOf(this.background); this.post({ type: 'prefs', background: list[(i + 1) % list.length] }); }
      else if (cmd === 'full') this.post({ type: 'prefs', fullscreen: !this.fullscreen });
      else if (cmd === 'follow') { this.follow = !this.follow; this.post({ type: 'prefs', follow: this.follow }); this.hudButtons(); }
      else if (cmd === 'gyro') { this.gyro = !this.gyro; this.poseLast = null; this.poseF = null; this.post({ type: 'prefs', gyro: this.gyro }); this.toast(this.gyro ? t('转动设备环顾：已打开') : t('转动设备环顾：已关闭')); this.hudButtons(); }
      else this.command(cmd);
    });
    $('ar-edges').addEventListener('click', (e) => {
      const b = e.target.closest('[data-id]');
      if (b) this.focus(this.panels.get(b.dataset.id));
    });
  }

  askExit() {
    const now = performance.now();
    if (now - (this.exitAsk || 0) < 2200) { this.post({ type: 'exit' }); return; }
    this.exitAsk = now;
    this.toast(t('再按一次 Esc 退出 AR 模式'));
  }

  wantHover(p) {
    if (this.pinned) return;
    if (this.focused || this.look) p = null;
    if (p === this.hoverWant) return;
    this.hoverWant = p;
    clearTimeout(this.hoverTimer);
    // 进来稍等一下（扫过去不算），离开多给一点时间（窗口在飞的时候边缘会挪）
    this.hoverTimer = setTimeout(() => this.setHover(this.hoverWant), p ? (this.hovered ? 70 : 150) : 280);
  }

  setHover(p) {
    if (p === this.hovered) return;
    if (this.pinned && p !== this.pinned) return;   // 停住的窗口不因为鼠标移开、拖动等缩回去，只有 unpin 能放开
    if (this.hovered) { this.hovered.el.classList.remove('hover'); if (this.hovered !== this.focused) this.hovered.setSize(PW, PH); }
    this.hovered = p;
    if (p) {
      p.el.classList.add('hover');
      // 窗口本身也放大（多显示几行），再飞到接近 1:1 的位置：看起来大一圈，字仍然清楚（只靠拉近会糊）
      p.setSize(Math.min(HOVER_W, innerWidth - 24), Math.min(HOVER_H, Math.round(innerHeight * 0.72)));   // 手机竖着只有三百多宽，别超出屏幕
      if (p instanceof SessionPanel) { p.render(); clearTimeout(this.seenTimer); this.seenTimer = setTimeout(() => { if (this.hovered === p) { p.seen(); this.stats(); } }, 1200); }
      this.peeked = null;
    }
    for (const q of this.panels.values()) q.el.classList.toggle('dim', !!p && q !== p && !this.focused);
    this.watchBrowsers();
    this.dirty = true;
  }

  forward() {
    const y = this.cam.yaw, p = this.cam.pitch;
    return new THREE.Vector3(-Math.sin(y) * Math.cos(p), Math.sin(p), -Math.cos(y) * Math.cos(p));
  }

  // MARK: 每帧
  frame(now) {
    requestAnimationFrame((n) => this.frame(n));
    this.update(now);
  }

  /// 自测用：测试实例的窗口不在屏幕上，WebKit 停了 requestAnimationFrame 和 CSS 动画——手动往前走 n 帧，动画全部直接到终态
  tick(n = 90) {
    document.body.classList.add('still');
    let now = performance.now();
    this.last = now;
    for (let i = 0; i < n; i++) { now += 1000 / 60; this.update(now); }
    this.hudAt = 0; this.hudDirty = true; this.update(now + 100);
    return this.panels.size;
  }

  update(now) {
    if (!this.visible) return;
    const dt = Math.min(0.05, (now - this.last) / 1000);
    this.last = now;
    let moving = false;

    // 键盘走动（按镜头朝向，水平面内），Shift 加速
    const ks = this.keys;
    if (ks.size) {
      const fast = ks.has('shift') ? 2.6 : 1;
      const v = 1100 * fast * dt;
      const yaw = this.cam.yaw;
      const fwd = new THREE.Vector3(-Math.sin(yaw), 0, -Math.cos(yaw));
      const right = new THREE.Vector3(Math.cos(yaw), 0, -Math.sin(yaw));
      if (ks.has('w')) this.cam.pos.addScaledVector(fwd, v);
      if (ks.has('s')) this.cam.pos.addScaledVector(fwd, -v);
      if (ks.has('d')) this.cam.pos.addScaledVector(right, v);
      if (ks.has('a')) this.cam.pos.addScaledVector(right, -v);
      if (ks.has('e')) this.cam.pos.y += v * 0.7;
      if (ks.has('q')) this.cam.pos.y -= v * 0.7;
      if (ks.has('ArrowLeft')) this.cam.yaw += 1.5 * dt;
      if (ks.has('ArrowRight')) this.cam.yaw -= 1.5 * dt;
      if (ks.has('ArrowUp')) this.cam.pitch = clamp(this.cam.pitch + 1.1 * dt, -1.15, 1.15);
      if (ks.has('ArrowDown')) this.cam.pitch = clamp(this.cam.pitch - 1.1 * dt, -1.15, 1.15);
      moving = true;
      this.lastInput = now;
    }

    // 鼠标停在屏幕左右边缘（中间那段）：慢慢转过去，像转头。只在全屏时：窗口模式下边缘是拖着改窗口大小的地方
    const m = this.mouse;
    const edge = this.fullscreen && m.inside && !this.look && !this.focused && !this.hovered && m.y > innerHeight * 0.22 && m.y < innerHeight * 0.8
      ? (m.x < 8 ? 1 : m.x > innerWidth - 8 ? -1 : 0) : 0;
    if (edge) {
      this.edgeSince ||= now;
      const ramp = clamp((now - this.edgeSince - 260) / 700, 0, 1);
      if (ramp > 0) { this.cam.yaw += edge * 0.95 * ramp * dt; this.flying = 0; moving = true; }
    } else this.edgeSince = 0;

    // 视差：镜头朝鼠标那边略微偏一点（像头跟着眼睛转），指着窗口、打开着、拖动时不动
    // 视差（镜头随鼠标微偏）关掉：鼠标一动就要重排所有窗口的变换，11-21 觉得卡
    const calm = false;
    const py = calm ? -(m.x / innerWidth - 0.5) * 0.045 : 0;
    const pp = calm ? -(m.y / innerHeight - 0.5) * 0.03 : 0;
    this.para.yaw += (py - this.para.yaw) * damp(3, dt);
    this.para.pitch += (pp - this.para.pitch) * damp(3, dt);

    // 跟随时飘过来的窗口：时间到了放回去
    if (this.peeked && now > this.peekUntil) { this.peeked = null; moving = true; }

    // 镜头追目标
    const flying = this.flying && now - this.flying < 2200;
    const a = damp(flying ? this.fly : 14, dt);
    const c = this.cur;
    const before = c.pos.x + c.pos.y + c.pos.z + c.yaw + c.pitch;
    c.pos.lerp(this.cam.pos, a);
    c.yaw += (this.cam.yaw - c.yaw) * a;
    c.pitch += (this.cam.pitch - c.pitch) * a;
    if (Math.abs(before - (c.pos.x + c.pos.y + c.pos.z + c.yaw + c.pitch)) > 1e-4) moving = true;
    this.camera.position.copy(c.pos);
    this.camera.rotation.set(c.pitch + this.para.pitch, c.yaw + this.para.yaw, 0, 'YXZ');
    this.camera.updateMatrixWorld();

    // 窗口追各自的目标：平时在墙上；指着的 / 跟随飘来的飞到眼前、正对着你；打开的往前挪一点
    const pa = damp(9, dt);
    for (const p of this.panels.values()) {
      if (!p.rest) continue;
      let pos = p.rest.pos, quat = p.rest.quat;
      if (p === this.focused && p.focusPos) pos = p.focusPos;
      else if (p === this.hovered || p === this.peeked) {
        const eye = this.camera.position;
        const dir = p.rest.pos.clone().sub(eye);
        // 停住的（点了 / 在打字）飘到视野正中，整块看得见；只是悬停的沿视线往前拉
        const dist = dir.length();
        const want = this.P / HOVER_SCALE;
        pos = dist > want ? eye.clone().addScaledVector(dir.normalize(), want) : p.rest.pos.clone().addScaledVector(dir.normalize(), -60);
        // 和镜头的成像面平行（正对屏幕，不是对着眼睛转）：看起来是端正的长方形，不带梯形
        quat = this.camera.quaternion;
      }
      const o = p.obj;
      if (o.position.distanceToSquared(pos) > 0.01 || o.quaternion.angleTo(quat) > 1e-4) {
        o.position.lerp(pos, pa);
        o.quaternion.slerp(quat, pa);
        moving = true;
      }
    }
    for (const l of this.labels.values()) {
      if (l.rest && l.obj.position.distanceToSquared(l.rest.pos) > 0.01) { l.obj.position.lerp(l.rest.pos, pa); l.obj.quaternion.slerp(l.rest.quat, pa); moving = true; }
    }

    if (moving || this.dirty) {
      this.renderer.render(this.scene, this.camera);
      this.dirty = false;
      this.hudDirty = true;
    }
    // 有消息的窗口隔一会儿抖一下（错开一点，不齐刷刷地抖）
    if (now - this.lastPing > PING_EVERY) {
      this.lastPing = now;
      let i = 0;
      for (const p of this.panels.values()) {
        if (p.attn && p !== this.focused && p !== this.hovered) setTimeout(() => p.ping(), (i++ % 4) * 90);
      }
    }
    if (now - (this.hudAt || 0) > 400) this.hudDirty = true;   // 雷达上的闪点、穿透模式的范围也要慢慢刷
    if (this.hudDirty && now - (this.hudAt || 0) > 90) { this.hudAt = now; this.hudDirty = false; this.hud(); }
  }

  // MARK: 屏幕上的 HUD：顶上罗盘、右上统计、右下雷达、屏幕边缘的方向标
  hud() {
    const yaw = this.cur.yaw + this.para.yaw;
    // 罗盘：每 15° 一格，标出有消息 / 等确认的窗口方向
    const deg = ((-yaw * 180 / Math.PI) % 360 + 360) % 360;
    $('ar-heading').textContent = Math.round(deg) + '°';
    const span = 120, wpx = 420;
    let ticks = '';
    for (let d = Math.ceil((deg - span / 2) / 15) * 15; d <= deg + span / 2; d += 15) {
      const x = (d - deg) / span * wpx + wpx / 2;
      const major = ((d % 90) + 90) % 90 === 0;
      ticks += `<i class="${major ? 'mj' : ''}" style="left:${x.toFixed(1)}px">${major ? `<em>${((d % 360) + 360) % 360}</em>` : ''}</i>`;
    }
    const eye = this.camera.position;
    const v = new THREE.Vector3();
    const edges = [];
    for (const p of this.panels.values()) {
      if (!p.rest) continue;
      v.copy(p.rest.pos).sub(eye);
      const bearing = Math.atan2(-v.x, -v.z);
      const rel = wrapAngle(bearing - yaw) * 180 / Math.PI;
      if (p.attn && Math.abs(rel) < span / 2) ticks += `<b class="${p.status === 'waiting' ? 'w' : ''}" style="left:${(-rel / span * wpx + wpx / 2).toFixed(1)}px"></b>`;
      if (p.attn && p !== this.focused) {
        // 看不见的：投影到屏幕外（或在身后）就在边上标出方向
        const ndc = p.rest.pos.clone().project(this.camera);
        const behind = v.dot(this.forward()) < 0;
        if (behind || Math.abs(ndc.x) > 1 || Math.abs(ndc.y) > 1) {
          let x = behind ? -ndc.x : ndc.x, y = behind ? -ndc.y : ndc.y;
          if (behind && Math.abs(x) < 1e-3) x = 1;
          const sc = 1 / Math.max(Math.abs(x), Math.abs(y), 1e-3);
          x *= sc; y *= sc;
          edges.push({ p, x: (x * 0.5 + 0.5) * innerWidth, y: (-y * 0.5 + 0.5) * innerHeight, ang: Math.atan2(-y, x) });
        }
      }
    }
    $('ar-compass-in').innerHTML = ticks;
    // 边缘方向标
    const box = $('ar-edges');
    const html = edges.slice(0, 8).map(({ p, x, y, ang }) => {
      const s = this.sessions.get(p.key);
      // 让开右下角的按钮和雷达
      const cx = clamp(x, 90, innerWidth - 150), cy = clamp(y, 104, innerHeight - (x > innerWidth - 300 ? 420 : 90));
      return `<button data-id="${esc(p.id)}" class="${p.status === 'waiting' ? 'w' : ''}" style="left:${cx.toFixed(0)}px;top:${cy.toFixed(0)}px">` +
        `<i style="transform:rotate(${(ang * 180 / Math.PI).toFixed(0)}deg)"></i><span>${esc(s?.title || '')}</span></button>`;
    }).join('');
    if (html !== this.edgeHTML) { this.edgeHTML = html; box.innerHTML = html; }
    this.radar(yaw);
    if (this.passthrough) this.reportRects();
  }

  radar(yaw) {
    const cv = $('ar-radar'), g = cv.getContext('2d');
    const dpr = devicePixelRatio || 1, S = 150;
    if (cv.width !== S * dpr) { cv.width = cv.height = S * dpr; }
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, S, S);
    const R = S / 2 - 6, cx = S / 2, cy = S / 2;
    g.strokeStyle = 'rgba(255,255,255,.14)'; g.lineWidth = 1;
    for (const r of [R, R * 0.66, R * 0.33]) { g.beginPath(); g.arc(cx, cy, r, 0, Math.PI * 2); g.stroke(); }
    // 视野扇形
    const half = Math.atan(Math.tan(THREE.MathUtils.degToRad(this.camera.fov / 2)) * this.camera.aspect);
    g.fillStyle = 'rgba(255,255,255,.06)';
    g.beginPath(); g.moveTo(cx, cy); g.arc(cx, cy, R, -Math.PI / 2 - half, -Math.PI / 2 + half); g.closePath(); g.fill();
    const range = Math.max(1200, (this.D || 2000) * 1.9);
    const eye = this.camera.position;
    const cos = Math.cos(yaw), sin = Math.sin(yaw);
    const blink = (performance.now() % 1200) < 700;
    const brand = getComputedStyle(document.documentElement).getPropertyValue('--brand').trim() || '#D97757';
    for (const p of this.panels.values()) {
      if (!p.rest) continue;
      const dx = p.rest.pos.x - eye.x, dz = p.rest.pos.z - eye.z;
      // 转到「朝前 = 上」的坐标
      const rx = dx * cos - dz * sin, rz = dx * sin + dz * cos;
      let x = rx / range * R, y = rz / range * R;
      const len = Math.hypot(x, y);
      if (len > R - 3) { x *= (R - 3) / len; y *= (R - 3) / len; }
      const st = p.status || 'idle';
      g.fillStyle = st === 'waiting' ? '#F2A33A' : st === 'busy' ? brand : st === 'error' ? '#FF5F57' : 'rgba(255,255,255,.5)';
      if (p.attn && !blink) g.fillStyle = 'rgba(255,255,255,.9)';
      g.beginPath(); g.arc(cx + x, cy + y, p === this.focused || p === this.hovered ? 3.6 : 2.4, 0, Math.PI * 2); g.fill();
    }
    g.fillStyle = '#fff';
    g.beginPath(); g.moveTo(cx, cy - 6); g.lineTo(cx + 4, cy + 4); g.lineTo(cx - 4, cy + 4); g.closePath(); g.fill();
  }

  /// 穿透模式：把窗口、按钮在屏幕上的范围报给宿主，宿主只在这些地方接鼠标，其余点击落到桌面上
  reportRects() {
    const rects = [];
    const add = (el) => {
      if (!el || el.hidden) return;
      const r = el.getBoundingClientRect();
      if (r.width > 2 && r.height > 2 && r.right > 0 && r.bottom > 0 && r.left < innerWidth && r.top < innerHeight) rects.push([Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)]);
    };
    for (const p of this.panels.values()) add(p.inner);
    for (const b of $('ar-edges').children) add(b);
    add($('ar-tools'));
    const sig = JSON.stringify(rects);
    if (sig === this.rectSig) return;
    this.rectSig = sig;
    this.post({ type: 'rects', rects });
  }

  stats() {
    let busy = 0, waiting = 0, unread = 0, n = 0;
    for (const p of this.panels.values()) {
      if (!(p instanceof SessionPanel)) continue;
      n++;
      if (p.status === 'busy') busy++;
      if (p.status === 'waiting') waiting++;
      if (p.unread) unread++;
    }
    const parts = [`<b>${n}</b>${esc(t('会话'))}`, `<b>${busy}</b>${esc(t('在工作'))}`];
    if (waiting) parts.push(`<b class="w">${waiting}</b>${esc(t('待确认'))}`);
    if (unread) parts.push(`<b class="u">${unread}</b>${esc(t('新消息'))}`);
    $('ar-stats-n').innerHTML = parts.map(x => `<span>${x}</span>`).join('');
  }

  clock() {
    const d = new Date();
    $('ar-clock').textContent = `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
  }

  hudButtons() {
    const tools = $('ar-tools');
    if (!tools) return;
    const layoutName = { arc: t('弧形'), ring: t('环绕'), flat: t('平面') }[this.layoutMode] || t('弧形');
    const bgName = ({ none: this.touch ? t('相机') : t('透明'), space: t('宇宙'), sky: t('天空'), sea: t('海面'), forest: t('森林'), aurora: t('极光'), video: t('视频') })[this.background] || t('背景');
    // iPad 上没有「穿透」「全屏」（整屏本来就是 AR），多一个「陀螺仪」
    tools.innerHTML = (this.touch ? [
      ['home', t('复位'), 'R'],
      ['layout', layoutName, 'L'],
      ['follow', t('跟随'), 'F', this.follow],
      ['gyro', t('陀螺仪'), 'G', this.gyro],
      ['bg', bgName, 'B', this.background !== 'none'],
      ['hint', t('操作'), 'H'],
    ] : [
      ['home', t('复位'), 'R'],
      ['layout', layoutName, 'L'],
      ['follow', t('跟随'), 'F', this.follow],
      ['bg', bgName, 'B', this.background !== 'none'],
      ['pass', t('穿透'), 'P', this.passthrough],
      ['full', this.fullscreen ? t('窗口') : t('全屏'), 'M', this.fullscreen],
      ['hint', t('操作'), 'H'],
    ]).map(([cmd, label, key, on]) => `<button data-cmd="${cmd}" class="${on ? 'on' : ''}" title="${esc(label)}（${key}）"><span>${esc(label)}</span><kbd>${key}</kbd></button>`).join('');
  }

  hint(force) {
    const el = $('ar-hint');
    const show = force === true || el.classList.contains('gone');
    el.classList.toggle('gone', !show);
    clearTimeout(this.hintTimer);
    if (show) this.hintTimer = setTimeout(() => el.classList.add('gone'), 9000);
  }

  toast(text) {
    const el = $('ar-toast');
    el.textContent = text;
    el.hidden = false;
    el.classList.remove('out');
    clearTimeout(this.toastTimer);
    this.toastTimer = setTimeout(() => { el.classList.add('out'); setTimeout(() => { el.hidden = true; }, 300); }, 1800);
  }
}

const ar = new AR();
window.World = { receive: (msg) => ar.receive(msg), ar };
if (window.chrome?.webview) window.chrome.webview.addEventListener('message', (e) => ar.receive(e.data));

const params = new URLSearchParams(location.search);
if (params.has('t')) {
  // 直连模式（浏览器 / WebView2）：自己连接口（api.js 会接管 host.post、填好 mediaBase / mediaSuffix）
  ar.host = host;
  import('./api.js').then(({ startApi }) => startApi(ar, params));
} else if (host.connected && !params.has('demo')) {
  host.post({ type: 'ready' });
} else {
  import('./ardemo.js').then(({ startDemo }) => startDemo(ar));
}
