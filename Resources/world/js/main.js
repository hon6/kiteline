// Kiteline 世界：机房（agent）、卫星（设备）、乐高小人（会话）。
// 这一份网页各端共用（Mac / iPhone 的 WKWebView、Windows 的 WebView2、Linux 的 WebKitGTK）：
// 主程序把 Kiteline 接口的数据原样转进来（World.receive），点了什么用 postMessage 告诉主程序。
//
// 主程序 → 世界：{type:'init', lang, strings, brand, quality, insets, door, mediaBase, marks}
//               {type:'state', state}（/api/state 整份） {type:'entries', key, items} {type:'peers', links, backfill}
//               {type:'sys', id, stats} {type:'todos', items, initial} {type:'focus', key} {type:'active', active, visible}
//               {type:'view', name} {type:'insets', top}
// 世界 → 主程序：{type:'ready'} {type:'open', key}（看会话详情） {type:'select', key} {type:'machine', sourceId} {type:'exit'}
//
// 性能：同类零件实例化、动画在着色器里算、没有实时阴影和后期处理；平时 30 帧，拖动、飞镜头、有光弧时 60 帧，
// 窗口不在前台 12 帧，看不见就停；帧时间长期超标自动降分辨率。

import * as THREE from '../vendor/three.module.min.js';
import { OrbitControls } from '../vendor/addons/controls/OrbitControls.js';
import { WorldData } from './data.js';
import { computeLayout } from './layout.js';
import { palette, groundMaterial } from './parts.js';
import { Office } from './office.js';
import { DataCenter } from './datacenter.js';
import { Sky } from './sky.js';
import { Effects } from './fx.js';
import { Hud } from './hud.js';
import { Photos } from './photos.js';
import { Social } from './social.js';
import { Board } from './board.js';
import { ZoneSigns } from './signs.js';
import { Meter } from './meter.js';
import { Walls } from './walls.js';
import { Voice } from './voice.js';
import { Nav } from './nav.js';
import { setStrings, t } from './i18n.js';

const host = {
  connected: !!(window.webkit?.messageHandlers?.world || window.chrome?.webview),
  post(msg) {
    try {
      if (window.webkit?.messageHandlers?.world) window.webkit.messageHandlers.world.postMessage(msg);
      else if (window.chrome?.webview) window.chrome.webview.postMessage(msg);
      else if (window.parent !== window) window.parent.postMessage({ kiteline: msg }, '*');
    } catch { /* 主程序不在：演示模式 */ }
  },
};

const ease = (u) => (u < 0.5 ? 4 * u * u * u : 1 - Math.pow(-2 * u + 2, 3) / 2);

class World {
  constructor() {
    this.host = host;
    this.root = document.getElementById('world');
    this.canvas = document.getElementById('scene');
    this.brand = 0xD97757;
    this.mediaBase = '';
    this.marks = {};
    this.time = 0;
    this.ready = false;
    this.selected = null;
    this.hovered = null;
    this.active = true;
    this.visible = true;
    this.dirty = true;
    this.inflight = new Map();
    this.live = new Map();
    try { this.follow = localStorage.getItem('world.follow') === '1'; } catch { this.follow = false; }

    const dpr = window.devicePixelRatio || 1;
    this.renderer = new THREE.WebGLRenderer({ canvas: this.canvas, antialias: dpr < 2, powerPreference: 'high-performance', stencil: false });
    this.maxPixelRatio = Math.min(dpr, 2);
    this.pixelRatio = this.maxPixelRatio;
    this.renderer.setPixelRatio(this.pixelRatio);

    this.palette = palette();
    this.scene = new THREE.Scene();
    this.scene.background = new THREE.Color(this.palette.canvas);
    this.scene.fog = new THREE.Fog(this.palette.canvas, 160, 520);
    // 近处裁剪面别太近：远处的深度精度高一些，贴得近的两个面不来回闪
    this.camera = new THREE.PerspectiveCamera(36, 1, 2, 1600);
    this.camera.position.set(0, 70, 90);

    const p = this.palette;
    this.scene.add(new THREE.HemisphereLight(p.hemiSky, p.hemiGround, p.hemi));
    const sun = new THREE.DirectionalLight(p.sunColor, p.sun);
    sun.position.set(-40, 80, 50);
    this.scene.add(sun);
    this.ground = new THREE.Mesh(new THREE.PlaneGeometry(3000, 3000).rotateX(-Math.PI / 2), groundMaterial(p));
    this.ground.renderOrder = -5;
    this.scene.add(this.ground);

    // 左键（单指）拖地板 = 平移，右键或按住 ⇧ / ⌘ 拖 = 转视角，滚轮 / 双指 = 远近
    this.controls = new OrbitControls(this.camera, this.canvas);
    Object.assign(this.controls, {
      enableDamping: true, dampingFactor: 0.08, screenSpacePanning: false,
      minDistance: 10, maxDistance: 260, minPolarAngle: 0.15, maxPolarAngle: 1.36, zoomSpeed: 0.9, rotateSpeed: 0.6, panSpeed: 1.1,
      mouseButtons: { LEFT: THREE.MOUSE.PAN, MIDDLE: THREE.MOUSE.DOLLY, RIGHT: THREE.MOUSE.ROTATE },
      touches: { ONE: THREE.TOUCH.PAN, TWO: THREE.TOUCH.DOLLY_ROTATE },
    });
    this.controls.addEventListener('start', () => { this.tween = null; this.touched = performance.now(); });
    this.controls.addEventListener('change', () => { this.clampView(); this.dirty = true; });

    this.data = new WorldData();
    this.office = new Office(this);
    this.dc = new DataCenter(this);
    this.sky = new Sky(this);
    this.fx = new Effects(this);
    this.photos = new Photos(this);
    this.social = new Social(this);
    this.board = new Board(this);
    this.signs = new ZoneSigns(this);
    this.meter = new Meter(this);
    this.walls = new Walls(this);
    this.voice = new Voice(this);
    this.hud = new Hud(this, document.getElementById('hud'));
    this.hud.setFollow(this.follow);
    this.hud.setVoice(this.voice.on);

    this.bindPointer();
    this.bindKeys();
    new ResizeObserver(() => this.resize()).observe(this.root);
    this.resize();
    document.addEventListener('visibilitychange', () => this.schedule());
    this.lastFrame = performance.now() / 1000;
    this.frameAvg = 1 / 30;
    this.schedule();
  }

  // MARK: 主程序来的消息

  receive(msg) {
    if (!msg || !msg.type) return;
    switch (msg.type) {
      case 'init': this.init(msg); break;
      case 'state': this.onState(msg.state || msg); break;
      case 'entries': this.onEntries(msg.key, msg.items); break;
      case 'peers': for (const p of this.data.applyPeers(msg.links, msg.backfill)) this.peer(p); break;
      case 'sys': this.data.applySys(msg.id, msg.stats); this.refreshLabels(); break;
      case 'focus': if (msg.key) this.focusSession(msg.key); break;
      case 'active':
        this.active = msg.active !== false;
        this.visible = msg.visible !== false;
        if (!this.visible) this.voice.stop();   // 看不见（离开世界、窗口被挡住）就别念了
        this.schedule();
        break;
      case 'view': this.view(msg.name); break;
      case 'insets': this.setInsets(msg); break;
      case 'sent': this.hud.chat.sent(msg.ok); break;
      case 'dictation': this.hud.chat.dictation(msg); break;
      case 'todos':
        // 待办在状态之前到：先存着，排好位置再贴
        this.todos = msg;
        if (this.ready) this.board.apply(msg.items, !!msg.initial || !this.todosSeen);
        this.todosSeen = this.ready;
        break;
      case 'usage':
        this.usage = msg;
        this.meter.apply(msg);
        this.refreshLabels();
        break;
    }
  }

  init(opts) {
    setStrings(opts.lang, opts.strings);
    document.documentElement.lang = opts.lang === 'en' ? 'en' : 'zh-CN';
    this.hud.relabel();   // 界面是在 init 之前按中文搭的：换成当前语言
    if (opts.brand) {
      this.brand = new THREE.Color(opts.brand).getHex(THREE.SRGBColorSpace);
      document.documentElement.style.setProperty('--brand', opts.brand);
    }
    this.mediaBase = opts.mediaBase || '';
    this.voice.setVoices(opts.voices);
    this.marks = opts.marks || {};
    this.setInsets(opts.insets || {});
    this.hud.door.hidden = !opts.door;
    if (opts.quality === 'low') this.maxPixelRatio = Math.min(this.maxPixelRatio, 1.25);
    else if (opts.quality === 'medium') this.maxPixelRatio = Math.min(this.maxPixelRatio, 1.6);
    this.pixelRatio = this.maxPixelRatio;
    this.renderer.setPixelRatio(this.pixelRatio);
    this.hud.refreshStats();
    this.resize();
  }

  /// 被盖住的边（标题栏、Mac 的侧栏浮在左边）：网页层让开，画面的中心也挪到看得见的那块中间
  setInsets(insets) {
    this.insets = { ...this.insets, ...insets };
    for (const side of ['top', 'right', 'bottom', 'left']) document.documentElement.style.setProperty('--inset-' + side, (this.insets[side] || 0) + 'px');
    this.resize();
  }

  onState(state) {
    // 牌子、头像牌要用像素字画：第一次先等字体加载好（最多 1.5 秒）
    if (!this.fontLoaded) {
      this.pendingState = state;
      if (!this.fontWait) {
        this.fontWait = Promise.race([document.fonts.load('12px "Pixel"'), new Promise(r => setTimeout(r, 1500))]).catch(() => {}).then(() => {
          this.fontLoaded = true;
          this.onState(this.pendingState);
        });
      }
      return;
    }
    const diff = this.data.applyState(state);
    const signature = [...this.data.sessions.values()].map(s => s.key + '|' + s.project + '|' + s.agent).sort().join(',') + '#' + [...this.data.sources.keys()].join(',');
    if (!this.ready || signature !== this.signature) {
      this.signature = signature;
      if (this.ready && diff.removed.length) {
        // 要走的人先升上去，1.1 秒后再重排
        for (const key of diff.removed) {
          const pos = this.office.deskCenter(key);
          if (pos) this.fx.beam(pos.setY(0), 0xFFFFFF);
          this.office.leave(key);
          this.hud.drop('tag:' + key);
          this.hud.forget(key);
        }
        clearTimeout(this.rebuildTimer);
        this.rebuildTimer = setTimeout(() => this.rebuild(diff.added), 1100);
      } else {
        this.rebuild(diff.added);
      }
    } else {
      this.office.update(this.data);
      this.dc.updateRates(this.data);
      this.sky.update(this.data);
      this.refreshLabels();
    }
    this.hud.refreshStats();
    this.dirty = true;
  }

  rebuild(added = []) {
    const first = !this.ready;
    this.layout = computeLayout(this.data);
    this.nav = new Nav(this.layout);
    this.office.build(this.layout, this.data, this.palette);
    this.dc.build(this.layout, this.data, this.palette);
    this.sky.build(this.layout, this.data);
    this.meter.build(this.layout, this.palette);
    this.walls.build(this.layout, this.palette);
    this.photos.place();
    if (this.todos && !this.todosSeen) { this.board.apply(this.todos.items, true); this.todosSeen = true; }
    this.board.relayout();
    this.signs.clear();
    this.hud.dropWhere(id => id.startsWith('zone:') || id.startsWith('room:') || id.startsWith('sat:') || id.startsWith('tag:'));
    this.refreshLabels();
    if (first) {
      this.ready = true;
      this.view('overview', true);
      this.intro();
      this.hud.chat.seed();

    } else {
      for (const key of added) {
        const pos = this.office.deskCenter(key);
        if (pos) this.fx.beam(pos.setY(0), this.brand);
      }
    }
    this.dirty = true;
  }

  /// 刚打开：最近活动的几个人依次冒出他们的最后一句话
  intro() {
    const recent = [...this.data.sessions.values()].sort((a, b) => b.updatedAt - a.updatedAt).slice(0, 3);
    recent.forEach((s, i) => {
      const message = this.data.latest.get(s.key);
      if (message) setTimeout(() => this.hud.bubble(s.key, message, { linger: 9 }), 600 + i * 450);
    });
  }

  /// 名牌、项目、机房、卫星的标签（内容变了才换）
  refreshLabels() {
    if (!this.layout) return;
    const d = this.data;
    for (const zone of this.layout.zones) {
      const list = zone.sessions.map(s => d.sessions.get(s.key)).filter(Boolean);
      const busy = list.filter(s => s.activity === 'busy').length, waiting = list.filter(s => s.activity === 'waiting').length;
      const used = (this.usage?.projects || []).filter(p => p.name === zone.name).reduce((sum, p) => sum + (p.input || 0) + (p.output || 0) + (p.cacheRead || 0) + (p.cacheWrite || 0), 0);
      const sub = [t('%@ 个会话', list.length), busy ? t('%@ 个在工作', busy) : '', waiting ? t('%@ 个待确认', waiting) : '', used ? t('今日 %@ token', compactNumber(used)) : ''].filter(Boolean).join(' · ');
      // 项目名和统计写在待办墙顶上的牌子里（signs.js），不再飘一块文字牌
      this.signs.set(zone, zone.name, sub);
    }
    for (const room of this.dc.rooms) {
      const label = this.dc.label(room, d);
      const html = `<b>${escape(label.name)}</b><span>${escape(label.sub)}</span>`;
      const item = this.hud.labels.get('room:' + room.agent);
      if (!item || item.node.innerHTML !== html) {
        const node = document.createElement('div');
        node.className = 'roomlabel';
        node.innerHTML = html;
        this.hud.label('room:' + room.agent, node, new THREE.Vector3(room.x + 2 + room.span / 2, 11.9, room.z + 2.2), { lod: 'mid', layer: 1 });
      }
    }
    for (const sat of this.sky.sats) {
      const source = d.sources.get(sat.id);
      const sys = d.sys[sat.id];
      const load = sys && sys.cpu != null ? `CPU ${Math.round(sys.cpu * 100)}%` + (sys.memTotal ? ` · ${t('内存')} ${Math.round(sys.memUsed / sys.memTotal * 100)}%` : '') : '';
      const html = `<i class="dot ${source?.online ? 'idle' : 'error'}"></i><b>${escape(source?.name || sat.id)}</b>${load ? `<span>${escape(load)}</span>` : ''}`;
      const item = this.hud.labels.get('sat:' + sat.id);
      if (!item || item.node.innerHTML !== html) {
        const node = document.createElement('div');
        node.className = 'satlabel';
        node.innerHTML = html;
        node.addEventListener('click', () => host.post({ type: 'machine', sourceId: sat.id }));
        this.hud.label('sat:' + sat.id, node, () => sat.pos.clone().add(new THREE.Vector3(0, 3.2, 0)), { lod: 'always', layer: 2 });
      }
    }
    for (const s of d.sessions.values()) {
      if (!this.office.has(s.key)) continue;
      this.hud.setStatus(s.key, this.statusOf(s));
      const html = `<i class="dot ${s.failed ? 'error' : s.activity}"></i><span>${escape(s.title)}</span>`;
      const item = this.hud.labels.get('tag:' + s.key);
      const pinned = s.activity === 'waiting' || s.failed;
      if (!item || item.node.innerHTML !== html || item.node.classList.contains('pinned') !== pinned) {
        const node = this.hud.nameTag(s);
        const key = s.key;
        // 休息的名牌垫在最底层（0），在忙、待确认、出错的和项目牌子一层（1）
        this.hud.label('tag:' + key, node, () => this.office.tagPos(key, new THREE.Vector3()), { lod: 'near', layer: node.classList.contains('resting') ? 0 : 1 });
      }
    }
  }

  /// 头顶最近的一条内容（对话增量来的）：一直显示到下一条
  setLive(key, status) {
    this.live.set(key, status);
    const s = this.data.sessions.get(key);
    if (s) this.hud.setStatus(key, this.statusOf(s));
  }

  /// 头顶小气泡的内容：等确认 → 在等什么；出错 → 原因；否则最近的一条内容（思考 / 动作 / 回复 / 你说的），
  /// 还没收到过内容时：在干活 → 工具名 + 在做什么，空闲 → 最后一句话
  statusOf(s) {
    if (s.failed) return { kind: 'error', text: s.error || s.line };
    if (s.activity === 'waiting') return { kind: 'wait', text: s.line };
    // 已经歇着（空闲、趴着睡）的人头顶不挂东西；刚回完的那句照样冒大气泡，收起后就没了
    if (s.activity !== 'busy') return { kind: 'none', text: '' };
    const live = this.live.get(s.key);
    if (live) return live;
    if (s.activity === 'busy') {
      const m = /^([A-Za-z][\w.-]*)[:：]\s*(.*)$/.exec(s.activityText || '');
      if (m) return { kind: 'tool', tool: m[1], text: m[2] };
      if (s.activityText) return { kind: 'tool', tool: s.activityText, text: '' };
      return { kind: 'tool', tool: t('工作中'), text: s.line };
    }
    const last = this.data.latest.get(s.key);
    return { kind: 'msg', text: last?.text || s.preview || '' };
  }

  // MARK: 消息：光弧、气泡、动态

  onEntries(key, items) {
    const events = this.data.applyEntries(key, items);
    if (!events.length || !this.ready) return;
    const s = this.data.sessions.get(key);
    // 同一批里只给最新的一条回复 / 你的一句话放光弧，工具调用闪个小签
    const last = [...events].reverse();
    const reply = last.find(e => e.kind === 'assistant' || e.kind === 'image');
    const mine = last.find(e => e.kind === 'user');
    const tool = last.find(e => e.kind === 'tool');
    const think = last.find(e => e.kind === 'think');
    // 头顶一直显示最近的那条内容（思考 / 动作 / 回复 / 你说的），直到下一条来；回复等光弧到了再换
    const newest = events[events.length - 1];
    if (newest.kind === 'think') this.setLive(key, { kind: 'think', text: newest.text });
    else if (newest.kind === 'tool') this.setLive(key, { kind: 'tool', tool: newest.name, text: newest.brief || '' });
    else if (newest.kind === 'user') this.setLive(key, { kind: 'user', text: newest.text });
    if (think) this.hud.chat.think(key, think.text, think.ts);
    for (const e of events) if (e.images?.length) for (const img of e.images) this.photos.add(s.project, this.mediaURL(key, img));
    if (mine) this.send(key, mine);
    if (reply) this.deliver(key, reply);
    if (tool) this.hud.chat.action(key, tool.name, tool.brief, tool.ts);
  }

  /// agent 的回复：机房天线 → 设备卫星 → 会话的电脑，到了屏幕一亮、头顶冒气泡
  deliver(key, message) {
    const s = this.data.sessions.get(key);
    if (!s || !this.office.has(key)) return;
    const pending = this.inflight.get(key);
    if (pending) { pending.message = message; return; }
    const entry = { message };
    this.inflight.set(key, entry);
    this.dc.aim(s.agent, s.sourceId);
    const points = [() => this.dc.feedPos(s.agent, new THREE.Vector3())];
    if (this.sky.position(s.sourceId)) points.push(() => this.sky.position(s.sourceId));
    points.push(() => this.office.screenPos(key, new THREE.Vector3()));
    this.fx.relay(points, {
      color: this.brand,
      onHop: (i) => { if (i === 0) this.sky.pulse(s.sourceId); },
      onLand: () => {
        this.inflight.delete(key);
        this.office.flash(key);
        const msg = { role: 'assistant', text: entry.message.text, images: entry.message.images, ts: entry.message.ts };
        this.hud.bubble(key, msg);
        this.hud.chat.reply(key, msg.text, msg.ts, msg.images);
        this.live.set(key, { kind: 'msg', text: msg.text });
        this.hud.status.set(key, this.statusOf(this.data.sessions.get(key) || {}));
        if (this.follow && performance.now() - (this.touched || 0) > 5000) this.focusSession(key, { quiet: true });
      },
    });
  }

  /// 你发的话：先在头顶冒出来，再从电脑经卫星送回机房（白色）
  send(key, message) {
    const s = this.data.sessions.get(key);
    if (!s || !this.office.has(key)) return;
    const msg = { role: 'user', text: message.text, images: message.images, ts: message.ts };
    this.hud.bubble(key, msg, { linger: 8 });
    this.hud.chat.user(key, msg.text, msg.ts, false, msg.images || []);
    const points = [() => this.office.screenPos(key, new THREE.Vector3())];
    if (this.sky.position(s.sourceId)) points.push(() => this.sky.position(s.sourceId));
    points.push(() => this.dc.feedPos(s.agent, new THREE.Vector3()));
    this.dc.aim(s.agent, s.sourceId);
    this.fx.relay(points, { color: 0xF2F2F2, onHop: (i) => { if (i === 0) this.sky.pulse(s.sourceId); } });
  }

  /// agent 之间发消息（SendMessage）：发信人和收信人站起来面对面聊（见 social.js），动态里记一条「A → B」
  peer(link) {
    if (!this.office.has(link.from) || !this.office.has(link.to)) return;
    this.social.message(link);
    this.social.feed(link);
  }

  mediaURL(key, img) {
    if (img.url) return img.url;
    return this.mediaBase + 'api/media?key=' + encodeURIComponent(key) + '&ref=' + encodeURIComponent(img.ref) + (this.mediaSuffix || '');
  }

  // MARK: 镜头

  /// 飞过去：target 看哪，dist 离多远，polar 俯角（0 = 正上方），azimuth 方位（0 = 从前面看）
  flyTo(target, dist, polar, azimuth, duration = 1.1) {
    const c = this.controls;
    const offset = this.camera.position.clone().sub(c.target);
    const sph = new THREE.Spherical().setFromVector3(offset);
    const toSph = new THREE.Spherical(dist ?? sph.radius, polar ?? sph.phi, azimuth ?? sph.theta);
    let dTheta = toSph.theta - sph.theta;
    dTheta = Math.atan2(Math.sin(dTheta), Math.cos(dTheta));
    this.tween = {
      start: performance.now() / 1000, duration,
      fromTarget: c.target.clone(), toTarget: target.clone(),
      from: { r: sph.radius, phi: sph.phi, theta: sph.theta },
      to: { r: toSph.radius, phi: toSph.phi, theta: sph.theta + dTheta },
    };
    this.schedule();
  }

  /// 镜头不出公司的墙：看的点限制在墙内；镜头跑到墙外时水平拉回来（高度不变，等于看得更陡一点）
  clampView() {
    const r = this.layout?.room;
    if (!r || this.clamping) return;
    this.clamping = true;
    const cam = this.camera.position, tg = this.controls.target, m = 2.5;
    const tx = Math.min(r.maxX - m, Math.max(r.minX + m, tg.x)), tz = Math.min(r.maxZ - m, Math.max(r.minZ + m, tg.z));
    if (tx !== tg.x || tz !== tg.z) { cam.x += tx - tg.x; cam.z += tz - tg.z; tg.x = tx; tg.z = tz; }
    const inside = (x, z) => x > r.minX + m && x < r.maxX - m && z > r.minZ + m && z < r.maxZ - m;
    if (!inside(cam.x, cam.z)) {
      const ox = cam.x - tg.x, oz = cam.z - tg.z;
      let lo = 0, hi = 1;
      for (let i = 0; i < 14; i++) { const mid = (lo + hi) / 2; if (inside(tg.x + ox * mid, tg.z + oz * mid)) lo = mid; else hi = mid; }
      cam.x = tg.x + ox * lo; cam.z = tg.z + oz * lo;
    }
    this.clamping = false;
  }

  stepTween(now) {
    const tw = this.tween;
    if (!tw) return;
    const u = Math.min(1, (now - tw.start) / tw.duration), k = ease(u);
    const target = tw.fromTarget.clone().lerp(tw.toTarget, k);
    const sph = new THREE.Spherical(tw.from.r + (tw.to.r - tw.from.r) * k, tw.from.phi + (tw.to.phi - tw.from.phi) * k, tw.from.theta + (tw.to.theta - tw.from.theta) * k);
    this.controls.target.copy(target);
    this.camera.position.copy(target).add(new THREE.Vector3().setFromSpherical(sph));
    this.clampView();
    this.camera.lookAt(target);
    if (u >= 1) this.tween = null;
    this.dirty = true;
  }

  /// 手机（短边不到 600）
  get phoneView() { return Math.min(innerWidth, innerHeight) < 600; }

  view(name, instant = false) {
    if (!this.layout) return;
    const b = this.layout.bounds;
    const duration = instant ? 0.001 : 1.2;
    if (name === 'rooms' && this.dc.rooms.length) {
      const first = this.dc.rooms[0];
      const minX = Math.min(...this.dc.rooms.map(r => r.x)), maxX = Math.max(...this.dc.rooms.map(r => r.x + r.w));
      this.flyTo(new THREE.Vector3((minX + maxX) / 2, 4, first.z + first.d / 2), Math.max(36, (maxX - minX) * 0.95), 1.05, 0, duration);
    } else if (name === 'sky') {
      this.flyTo(new THREE.Vector3(b.cx, 16, b.cz), Math.max(b.w, b.d) * 1.25 + 40, 1.3, 0.4, duration);
    } else {
      // 全景（一进来、点「全景」、双击空地都是它）：镜头放低、斜着看工位，后面是机房和计量牌；手机、iPad、电脑一样。
      // 按工位那片算距离（深按竖直视角、宽按水平视角，太宽就不全装下，两边自己拖着看）。10-27 起的：从头顶往下看太难认
      const vFov = THREE.MathUtils.degToRad(this.camera.fov) / 2;
      const hFov = Math.atan(Math.tan(vFov) * this.camera.aspect);
      const zs = this.layout.zones.length ? this.layout.zones : [{ x: b.cx - 10, z: b.cz - 10, w: 20, d: 20 }];
      const minX = Math.min(...zs.map(z => z.x)), maxX = Math.max(...zs.map(z => z.x + z.w));
      const minZ = Math.min(...zs.map(z => z.z)), maxZ = Math.max(...zs.map(z => z.z + z.d));
      const zw = maxX - minX, zd = maxZ - minZ;
      const fit = Math.max((zd / 2) / Math.tan(vFov), Math.min((zw / 2) / Math.tan(hFov), zw * 0.9), 34);
      this.flyTo(new THREE.Vector3((minX + maxX) / 2, 0, minZ + zd * 0.4), fit * 1.3, 1.1, -0.18, duration);
    }
  }

  focusSession(key, { quiet = false } = {}) {
    const pos = this.office.deskCenter(key, new THREE.Vector3());
    if (!pos) return;
    this.selected = key;
    const offset = this.camera.position.clone().sub(this.controls.target);
    const theta = Math.max(-0.8, Math.min(0.8, Math.atan2(offset.x, offset.z)));
    this.flyTo(pos, 26, 0.95, theta);
    if (!quiet) {
      const message = this.data.latest.get(key);
      if (message && !this.hud.bubbles.has(key)) this.hud.bubble(key, message, { linger: 10 });
    }
  }

  flyToZone(zone) {
    this.flyTo(new THREE.Vector3(zone.x + zone.w / 2, 1, zone.z + zone.d / 2), Math.max(30, Math.max(zone.w, zone.d) * 1.5), 0.9, 0);
  }

  /// 左上角点「待确认 / 工作中 / 出错」：依次飞到这些会话
  cycle(kind) {
    const list = [...this.data.sessions.values()].filter(s => (kind === 'error' ? s.failed : s.activity === kind) && this.office.has(s.key));
    if (!list.length) return;
    this.cycleIndex = ((this.cycleIndex ?? -1) + 1) % list.length;
    this.focusSession(list[this.cycleIndex].key);
  }

  setFollow(on) {
    this.follow = on;
    try { localStorage.setItem('world.follow', on ? '1' : '0'); } catch { /* 无痕模式 */ }
    this.hud.setFollow(on);
    this.hud.flashHint(on ? t('跟随最新消息：已打开') : t('跟随最新消息：已关闭'));
  }

  openSession(key) {
    this.selected = key;
    if (host.connected) host.post({ type: 'open', key });
    else this.hud.flashHint(t('打开会话：%@', this.data.sessions.get(key)?.title || key));
  }

  // MARK: 点选、悬停

  bindPointer() {
    const raycaster = new THREE.Raycaster();
    const ndc = new THREE.Vector2();
    let down = null, lastPick = 0, pending = null, lastTap = null, lastPointer = 'mouse';
    const pick = (x, y) => {
      const rect = this.canvas.getBoundingClientRect();
      ndc.set((x - rect.left) / rect.width * 2 - 1, -((y - rect.top) / rect.height) * 2 + 1);
      raycaster.setFromCamera(ndc, this.camera);
      const sat = this.sky.pick(raycaster);
      if (sat) return { type: 'satellite', id: sat };
      const hit = this.office.pick(raycaster);
      if (hit) return hit;
      const note = this.board.pick(raycaster);
      if (note) return { type: 'note', note };
      const photo = this.photos.pick(raycaster);
      if (photo) return { type: 'photo', url: photo };
      const room = this.dc.pick(raycaster);
      if (room) return { type: 'room', room };
      const zone = this.office.pickZone(raycaster, this.layout);
      if (zone) return { type: 'zone', zone };
      return null;
    };
    const hover = (x, y) => {
      const target = pick(x, y);
      const key = target && (target.type === 'screen' || target.type === 'figure') ? target.key : null;
      if (key !== this.hovered) { this.hovered = key; this.dirty = true; }
      this.canvas.style.cursor = target && target.type !== 'zone' ? 'pointer' : '';
      this.hud.showCard(target && target.type !== 'photo' ? target : null, x - this.root.getBoundingClientRect().left, y - this.root.getBoundingClientRect().top);
    };
    this.canvas.addEventListener('pointermove', (e) => {
      if (e.buttons) { this.hud.showCard(null); return; }
      pending = [e.clientX, e.clientY];
      const now = performance.now();
      if (now - lastPick > 50) { lastPick = now; hover(...pending); pending = null; }
      else clearTimeout(this.hoverTimer), this.hoverTimer = setTimeout(() => { if (pending) hover(...pending); }, 60);
    });
    this.canvas.addEventListener('pointerleave', () => { this.hud.showCard(null); this.hovered = null; });
    this.canvas.addEventListener('pointerdown', (e) => { down = { x: e.clientX, y: e.clientY, t: performance.now() }; lastPointer = e.pointerType; this.touched = performance.now(); });
    this.canvas.addEventListener('pointerup', (e) => {
      if (!down || Math.hypot(e.clientX - down.x, e.clientY - down.y) > 5 || performance.now() - down.t > 600) { down = null; return; }
      down = null;
      const target = pick(e.clientX, e.clientY);
      this.hud.showCard(null);
      // 手指双击空地 = 回到全景（触屏上不一定有 dblclick）
      if (!target && e.pointerType !== 'mouse') {
        const now = performance.now();
        if (lastTap && now - lastTap.t < 350 && Math.hypot(e.clientX - lastTap.x, e.clientY - lastTap.y) < 30) { lastTap = null; this.view('overview'); return; }
        lastTap = { x: e.clientX, y: e.clientY, t: now };
      }
      if (!target) { this.selected = null; return; }
      switch (target.type) {
        case 'screen': this.openSession(target.key); break;
        case 'figure':
          // 点人：镜头飞过去，左下角对话框选中他私聊
          this.focusSession(target.key);
          this.hud.chat.choose(target.key);
          break;
        case 'satellite': host.connected ? host.post({ type: 'machine', sourceId: target.id }) : this.hud.flashHint(t('设备详情')); break;
        case 'photo': this.hud.showImage(target.url); break;
        case 'note': if (target.note.owner && this.office.has(target.note.owner)) { this.focusSession(target.note.owner); host.post({ type: 'select', key: target.note.owner }); } break;
        case 'room': this.flyTo(this.dc.roomCenter(target.room.agent), Math.max(26, target.room.w * 1.3), 1.0, 0); break;
        case 'zone': this.flyToZone(target.zone); break;
      }
    });
    this.canvas.addEventListener('dblclick', (e) => { if (lastPointer === 'mouse' && !pick(e.clientX, e.clientY)) this.view('overview'); });
  }

  // MARK: 键盘：W A S D / 方向键 前后左右移动，Q E 左右转

  bindKeys() {
    this.keys = new Set();
    const map = { w: 'w', a: 'a', s: 's', d: 'd', q: 'q', e: 'e', arrowup: 'w', arrowleft: 'a', arrowdown: 's', arrowright: 'd',
      '=': '+', '+': '+', '-': '-', '_': '-' };
    window.addEventListener('keydown', (e) => {
      if (e.metaKey || e.ctrlKey || e.altKey || e.target?.isContentEditable || /input|textarea/i.test(e.target?.tagName || '')) return;
      const k = map[e.key.toLowerCase()];
      if (!k) return;
      e.preventDefault();
      this.keys.add(k);
      this.tween = null;
      this.touched = performance.now();
      this.schedule();
    });
    window.addEventListener('keyup', (e) => { const k = map[e.key.toLowerCase()]; if (k) this.keys.delete(k); });
    window.addEventListener('blur', () => this.keys.clear());
  }

  /// 按着键：沿着镜头朝向（贴着地面）前后左右挪，越远挪得越快；Q E 绕着看的点转
  stepKeys(dt) {
    if (!this.keys?.size) return;
    const cam = this.camera.position, tg = this.controls.target;
    const forward = new THREE.Vector3().subVectors(tg, cam).setY(0);
    if (forward.lengthSq() < 1e-6) forward.set(0, 0, -1);
    forward.normalize();
    const right = new THREE.Vector3(-forward.z, 0, forward.x);
    const speed = Math.max(12, cam.distanceTo(tg) * 0.9) * dt;
    const move = new THREE.Vector3();
    if (this.keys.has('w')) move.add(forward);
    if (this.keys.has('s')) move.sub(forward);
    if (this.keys.has('d')) move.add(right);
    if (this.keys.has('a')) move.sub(right);
    if (move.lengthSq()) { move.normalize().multiplyScalar(speed); cam.add(move); tg.add(move); }
    // + − 拉近拉远
    const zoom = (this.keys.has('-') ? 1 : 0) - (this.keys.has('+') ? 1 : 0);
    if (zoom) this.dolly(Math.exp(zoom * 1.6 * dt));
    const turn = (this.keys.has('q') ? 1 : 0) - (this.keys.has('e') ? 1 : 0);
    if (turn) {
      const offset = new THREE.Vector3().subVectors(cam, tg).applyAxisAngle(new THREE.Vector3(0, 1, 0), turn * 1.4 * dt);
      cam.copy(tg).add(offset);
    }
    this.clampView();
    this.touched = performance.now();
  }

  /// 拉近（factor < 1）/ 拉远（> 1）：看的点不动，镜头沿视线前后挪
  dolly(factor) {
    const cam = this.camera.position, tg = this.controls.target;
    const offset = new THREE.Vector3().subVectors(cam, tg);
    const length = Math.min(this.controls.maxDistance, Math.max(this.controls.minDistance, offset.length() * factor));
    cam.copy(tg).add(offset.setLength(length));
    this.clampView();
    this.dirty = true;
  }

  /// 右下角的 + − 按钮：一下拉近 / 拉远一档（带一点过渡）
  zoomStep(direction) {
    const offset = new THREE.Vector3().subVectors(this.camera.position, this.controls.target);
    const sph = new THREE.Spherical().setFromVector3(offset);
    const length = Math.min(this.controls.maxDistance, Math.max(this.controls.minDistance, sph.radius * (direction > 0 ? 0.72 : 1.38)));
    this.flyTo(this.controls.target.clone(), length, sph.phi, sph.theta, 0.35);
  }

  // MARK: 每帧

  resize() {
    const w = this.root.clientWidth || 1, h = this.root.clientHeight || 1;
    this.renderer.setSize(w, h, false);
    this.camera.aspect = w / h;
    // 竖着的手机：横向视角按正方形画面算（竖直视角放大，最多 60 度），不然左右只看得到窄窄一条
    this.camera.fov = w < h ? Math.min(60, 2 * THREE.MathUtils.radToDeg(Math.atan(Math.tan(THREE.MathUtils.degToRad(18)) * h / w))) : 36;
    // 左边被侧栏盖住、右边浮着会话页：画面中心挪到露出来的那块中间
    const left = Math.min(this.insets?.left || 0, w / 2), right = Math.min(this.insets?.right || 0, w / 2);
    // 竖着的手机：下面三分之一被对话框盖着，画面中心往上挪到露出来的那块中间
    const chat = this.hud?.chat?.node;
    const below = w < h && this.phoneView && chat ? Math.max(0, h - chat.getBoundingClientRect().top) : 0;
    if (left || right || below) this.camera.setViewOffset(w, h, (right - left) / 2, below * 0.25, w, h); else this.camera.clearViewOffset();
    // 露出来的那块太窄（侧栏、右边的会话页都开着）：操作提示收成「?」，别压住左下角的对话框
    document.documentElement.classList.toggle('cramped', w - left - right < 1000);
    this.camera.updateProjectionMatrix();
    this.size = { w, h };
    this.dirty = true;
    this.schedule();
  }

  invalidate() { this.dirty = true; }

  schedule() {
    const running = this.visible && !document.hidden;
    if (running && !this.raf) {
      this.lastFrame = performance.now() / 1000;
      this.raf = requestAnimationFrame((ms) => this.frame(ms));
    } else if (!running && this.raf) {
      cancelAnimationFrame(this.raf);
      this.raf = null;
    }
  }

  frame(ms) {
    this.raf = requestAnimationFrame((next) => this.frame(next));
    const now = ms / 1000;
    const lively = this.tween || this.fx.busy || this.keys?.size || performance.now() - (this.touched || 0) < 1500;
    const fps = lively ? 60 : this.active ? 30 : 12;
    if (now - this.lastFrame < 1 / fps - 0.004) return;
    const dt = Math.min(0.1, now - this.lastFrame);
    this.lastFrame = now;
    this.time += dt;
    this.adapt(dt, fps);

    this.stepTween(now);
    this.stepKeys(dt);
    this.controls.update();
    this.social.tick(this.time);
    this.office.tick(this.time, dt);
    this.dc.tick(this.time, dt);
    this.sky.tick(this.time, dt);
    this.fx.tick(this.time, dt);
    this.board.tick(this.time, dt);
    this.walls.tick();
    this.meter.tick(this.time);
    this.renderer.render(this.scene, this.camera);
    this.hud.update(this.camera, this.size.w, this.size.h);
    this.dirty = false;
  }

  /// 帧时间长期超过目标的 1.6 倍：分辨率降一档（最低 1 倍）
  adapt(dt, fps) {
    this.frameAvg += (dt - this.frameAvg) * 0.05;
    const budget = 1 / fps;
    if (this.frameAvg > budget * 1.6 && this.pixelRatio > 1) {
      this.slowSince ??= this.time;
      if (this.time - this.slowSince > 2.5) {
        this.pixelRatio = Math.max(1, this.pixelRatio - 0.25);
        this.renderer.setPixelRatio(this.pixelRatio);
        this.resize();
        this.slowSince = null;
        this.frameAvg = budget;
      }
    } else this.slowSince = null;
  }
}

function compactNumber(n) {
  if (n >= 1e9) return (n / 1e9).toFixed(1) + 'B';
  if (n >= 1e6) return (n / 1e6).toFixed(1) + 'M';
  if (n >= 1e3) return (n / 1e3).toFixed(1) + 'K';
  return String(Math.round(n));
}

function escape(text) {
  return String(text ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

const world = new World();
window.World = { receive: (msg) => world.receive(typeof msg === 'string' ? JSON.parse(msg) : msg), world };
window.chrome?.webview?.addEventListener('message', (e) => world.receive(e.data));
window.addEventListener('message', (e) => { if (e.data && e.data.kiteline) world.receive(e.data.kiteline); });
const params = new URLSearchParams(location.search);
// 直连模式的令牌：读到就存进本标签页的 sessionStorage，再从地址栏去掉（浏览器历史、地址栏里不留主令牌；刷新照样能用）
try {
  if (params.has('t')) {
    sessionStorage.setItem('world.t', params.get('t'));
    const rest = new URLSearchParams(params);
    rest.delete('t');
    history.replaceState(null, '', location.pathname + (rest.toString() ? '?' + rest : '') + location.hash);
  } else if (sessionStorage.getItem('world.t')) params.set('t', sessionStorage.getItem('world.t'));
} catch { /* 存不了（无痕、禁用存储）就照旧留在地址里 */ }
if (params.has('t')) {
  // 直连模式（Windows / Linux：从 Kiteline 服务的 /world/ 打开，地址带令牌）：自己连接口取数据
  import('./api.js').then(({ startApi }) => startApi(world, params));
} else {
  host.post({ type: 'ready' });
  // 没有主程序（直接用浏览器打开 ?demo）：放一段演示数据
  if (!host.connected || params.has('demo')) import('./demo.js').then(({ startDemo }) => startDemo(world));
}
