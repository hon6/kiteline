// 叠在三维画面上的网页层：名牌、气泡、项目 / 机房 / 卫星的标签，左上角统计，左下角动态，右下角视角按钮，悬停卡片，看大图。
// 标签每帧只在位置真变了时才改 transform，看不见的直接隐藏，不让排版拖慢画面。

import * as THREE from '../vendor/three.module.min.js';
import { t } from './i18n.js';
import { initials } from './atlas.js';
import { ChatBox } from './chatbox.js';

const v = new THREE.Vector3();

function el(tag, cls, html) {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (html != null) node.innerHTML = html;
  return node;
}

function esc(text) {
  return String(text ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

/// 消息里的 Markdown 记号去掉，只留文字
function plain(text) {
  return String(text || '').replace(/```[\s\S]*?```/g, ' ').replace(/[*_`#>]+/g, '').replace(/\[([^\]]+)\]\([^)]+\)/g, '$1').replace(/\s+/g, ' ').trim();
}

export function ago(ms) {
  if (!ms) return '';
  const s = Math.max(0, (Date.now() - ms) / 1000);
  if (s < 60) return t('刚刚');
  if (s < 3600) return t('%@ 分钟前', Math.floor(s / 60));
  if (s < 86400) return t('%@ 小时前', Math.floor(s / 3600));
  return t('%@ 天前', Math.floor(s / 86400));
}

const ICONS = {
  overview: '<svg viewBox="0 0 24 24"><path d="M4 9V5a1 1 0 0 1 1-1h4M15 4h4a1 1 0 0 1 1 1v4M20 15v4a1 1 0 0 1-1 1h-4M9 20H5a1 1 0 0 1-1-1v-4"/></svg>',
  rooms: '<svg viewBox="0 0 24 24"><rect x="5" y="3" width="14" height="18" rx="1.5"/><path d="M8 7h8M8 11h8M8 15h8"/><circle cx="16" cy="18" r=".6"/></svg>',
  sky: '<svg viewBox="0 0 24 24"><rect x="9" y="9" width="6" height="6" rx="1" transform="rotate(45 12 12)"/><path d="M3 7l4 4M17 13l4 4M7 3l4 4M13 17l4 4"/></svg>',
  follow: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M12 2v4M12 18v4M2 12h4M18 12h4"/></svg>',
  zoomin: '<svg viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg>',
  zoomout: '<svg viewBox="0 0 24 24"><path d="M5 12h14"/></svg>',
  voice: '<svg viewBox="0 0 24 24"><path d="M4 9h4l5-4v14l-5-4H4z"/><path d="M16 9.5a3.5 3.5 0 0 1 0 5M18.5 7a7 7 0 0 1 0 10"/></svg>',
  door: '<svg viewBox="0 0 24 24"><path d="M4 21h16M6 21V4a1 1 0 0 1 1-1h8v18M15 3l4 2v16"/><circle cx="12.5" cy="12" r=".9"/></svg>',
};

export class Hud {
  constructor(world, root) {
    this.world = world;
    this.root = root;
    this.labels = new Map();
    this.layer = el('div', 'labels');
    root.appendChild(this.layer);
    this.bubbles = new Map();
    this.chips = new Map();

    // 左上角统计
    this.stats = el('div', 'stats glass');
    root.appendChild(this.stats);
    this.stats.addEventListener('click', (e) => {
      const chip = e.target.closest('[data-cycle]');
      if (chip) this.world.cycle(chip.dataset.cycle);
    });
    // 左下角对话框（游戏聊天窗那种）
    this.chat = new ChatBox(world, root);
    /// 每个人头顶常驻的小气泡显示什么：{kind: tool / wait / error / msg, tool, text}
    this.status = new Map();
    // 右下角视角
    this.controls = el('div', 'controls glass');
    const buttons = [['zoomin', t('放大（拉近）')], ['zoomout', t('缩小（拉远）')], ['overview', t('全景')], ['rooms', t('机房')], ['sky', t('卫星')],
      ['follow', t('跟随最新消息')], ['voice', t('朗读 agent 之间的交谈（2 倍速）')]];
    for (const [id, title] of buttons) {
      const b = el('button', 'ctl', ICONS[id]);
      b.dataset.view = id;
      b.title = title;
      b.setAttribute('aria-label', title);
      this.controls.appendChild(b);
    }
    this.controls.addEventListener('click', (e) => {
      const b = e.target.closest('button');
      if (!b) return;
      if (b.dataset.view === 'follow') this.world.setFollow(!this.world.follow);
      else if (b.dataset.view === 'voice') {
        const on = this.world.voice.toggle();
        b.classList.toggle('on', on);
        this.flashHint(on ? t('朗读交谈：已打开') : t('朗读交谈：已关闭'));
      }
      else if (b.dataset.view === 'zoomin') this.world.zoomStep(1);
      else if (b.dataset.view === 'zoomout') this.world.zoomStep(-1);
      else this.world.view(b.dataset.view);
    });
    root.appendChild(this.controls);
    // 操作提示：右下角常驻，点一下收成「?」，再点展开（记住）
    this.help = el('div', 'help glass');
    const key = (k) => `<kbd>${k}</kbd>`;
    // 触屏（iPhone、iPad）：手势说明
    const rows = matchMedia('(pointer: coarse)').matches ? [
      [t('单指拖动'), t('移动视角')],
      [t('双指拖动'), t('转动视角')],
      [t('双指捏合'), t('放大缩小')],
      [t('轻点电脑屏幕'), t('查看会话')],
      [t('轻点人物'), t('私聊')],
      [`${t('双击')}${t('空地')}`, t('回到全景')],
    ] : [
      [`${key(t('左键'))}${t('拖动')}`, t('移动视角')],
      [`${key(t('右键'))}${t('拖动')}`, t('转动视角')],
      [`${key('⇧')}+${key(t('左键'))}${t('拖动')}`, t('转动视角')],
      [`${key(t('滚轮'))} / ${t('双指滑动、捏合')}`, t('放大缩小')],
      [`${key('+')}${key('−')}`, t('放大 / 缩小')],
      [`${key('W')}${key('A')}${key('S')}${key('D')}`, t('前后左右移动')],
      [`${key('Q')}${key('E')}`, t('向左 / 向右转')],
      [`${t('双击')}${t('空地')}`, t('回到全景')],
    ];
    this.help.innerHTML = `<div class="rows">${rows.map(([a, b]) => `<div class="row"><span class="keys">${a}</span><span>${esc(b)}</span></div>`).join('')}</div><button class="fold" title="${esc(t('操作提示'))}">?</button>`;
    let folded = false;
    try { folded = localStorage.getItem('world.helpFolded') === '1'; } catch { /* 无痕模式 */ }
    this.help.classList.toggle('folded', folded);
    this.help.addEventListener('click', () => {
      // 窄的时候点「?」：临时展开看一眼，再点收起
      if (document.documentElement.classList.contains('cramped')) { this.help.classList.toggle('opened'); return; }
      const now = !this.help.classList.contains('folded');
      this.help.classList.toggle('folded', now);
      try { localStorage.setItem('world.helpFolded', now ? '1' : '0'); } catch { /* 无痕模式 */ }
    });
    root.appendChild(this.help);
    // 没有原生按钮的端：右上角一扇开着的门，点了离开世界
    this.door = el('button', 'door glass', ICONS.door);
    this.door.title = t('离开世界');
    this.door.hidden = true;
    this.door.addEventListener('click', () => this.world.host.post({ type: 'exit' }));
    root.appendChild(this.door);
    // 悬停卡片、看大图、提示
    this.card = el('div', 'card glass');
    this.card.hidden = true;
    root.appendChild(this.card);
    this.lightbox = el('div', 'lightbox');
    this.lightbox.hidden = true;
    this.lightbox.addEventListener('click', () => { this.lightbox.hidden = true; });
    root.appendChild(this.lightbox);
    window.addEventListener('keydown', (e) => { if (e.key === 'Escape') this.lightbox.hidden = true; });
    this.hint = el('div', 'hint');
    root.appendChild(this.hint);
  }

  setFollow(on) {
    this.controls.querySelector('[data-view="follow"]').classList.toggle('on', on);
  }

  setVoice(on) {
    this.controls.querySelector('[data-view="voice"]').classList.toggle('on', on);
  }

  /// 正在说话：头顶旁边一组跳动的像素声波（跟着人走）
  speaking(key, on) {
    const id = 'voice:' + key;
    if (!on) { this.drop(id); return; }
    const node = el('div', 'voicewave', '<i></i><i></i><i></i><i></i>');
    const office = this.world.office, camera = this.world.camera;
    const side = new THREE.Vector3();
    this.label(id, node, () => {
      const p = office.headPos(key, new THREE.Vector3());
      if (!p) return null;
      side.setFromMatrixColumn(camera.matrixWorld, 0).setY(0).normalize();
      return p.addScaledVector(side, 1.0).add(v.set(0, -0.55, 0));
    }, { lod: 'mid', layer: 4 });
  }

  // MARK: 标签

  /// pos：取世界坐标的函数；lod：near（拉近了才显示）/ mid / always
  label(id, node, pos, { lod = 'always', layer = 0 } = {}) {
    let item = this.labels.get(id);
    if (!item) {
      // 外面一层只管位置（每帧改 transform），里面的节点自己做弹出、淡出的动画
      const anchor = el('div', 'anchor');
      anchor.appendChild(node);
      this.layer.appendChild(anchor);
      item = { anchor, node, pos, lod, last: '', shown: null };
      this.labels.set(id, item);
    } else if (item.node !== node) {
      item.node.replaceWith(node);
      item.node = node;
      item.w = 0;
    }
    item.anchor.style.zIndex = String(layer);
    item.pos = pos;
    item.lod = lod;
    return item;
  }

  drop(id) {
    const item = this.labels.get(id);
    if (item) { item.anchor.remove(); this.labels.delete(id); }
  }

  dropWhere(test) {
    for (const id of [...this.labels.keys()]) if (test(id)) this.drop(id);
  }

  update(camera, width, height) {
    const cam = camera.position;
    const bubbles = [], tags = [];
    for (const [id, item] of this.labels) {
      const p = typeof item.pos === 'function' ? item.pos() : item.pos;
      let visible = !!p && !item.node.dataset.hide;
      if (visible) {
        const dist = cam.distanceTo(p);
        if (item.lod === 'near' && dist > 75 && !item.node.classList.contains('pinned')) visible = false;
        if (item.lod === 'mid' && dist > 170 && !item.node.classList.contains('pinned')) visible = false;
        if (visible) {
          v.copy(p).project(camera);
          if (v.z > 1 || v.x < -1.2 || v.x > 1.2 || v.y < -1.2 || v.y > 1.3) visible = false;
          else {
            const x = Math.round((v.x + 1) / 2 * width), y = Math.round((1 - v.y) / 2 * height);
            if (id.startsWith('bubble:')) bubbles.push({ item, x, y, at: this.bubbles.get(id.slice(7))?.at || 0 });
            else if (id.startsWith('tag:') && !item.node.classList.contains('resting')) tags.push({ item, x, y });
            else this.place(item, x, y);
          }
        }
      }
      if (visible !== item.shown) { item.anchor.style.visibility = visible ? 'visible' : 'hidden'; item.shown = visible; }
    }
    // 气泡互相让开：新的先占位置，后面的被压住就往上挪
    // 新展开的大气泡先占位置，常驻的小气泡排后面；被压住就往上挪，小气泡挪两次还压着就先藏起来
    bubbles.sort((a, b) => b.at - a.at);
    const placed = [];
    for (const b of bubbles) {
      if (!b.item.w) { b.item.w = b.item.anchor.offsetWidth; b.item.h = b.item.anchor.offsetHeight; }
      const w = b.item.w, h = b.item.h;
      const small = b.at === 0;
      let y = b.y, clear = false;
      for (let pass = 0; pass < (small ? 2 : 6); pass++) {
        const hit = placed.find(r => Math.abs(r.x - b.x) < (r.w + w) / 2 + 4 && y > r.y - r.h - 3 && y - h < r.y + 3);
        if (!hit) { clear = true; break; }
        y = hit.y - hit.h - 5;
      }
      if (small && !clear) { b.item.anchor.style.visibility = 'hidden'; b.item.shown = false; continue; }
      if (b.item.shown === false) { b.item.anchor.style.visibility = 'visible'; b.item.shown = true; }
      placed.push({ x: b.x, y, w, h });
      this.place(b.item, b.x, y);
    }
    // 名牌之间也让开（拉远了只剩待确认、出错的名牌，挨着的工位最容易叠在一起）：屏幕上靠下（离镜头近）的先占，被压住的往上挪
    tags.sort((a, b) => b.y - a.y);
    const taken = [];
    for (const g of tags) {
      if (!g.item.w) { g.item.w = g.item.anchor.offsetWidth; g.item.h = g.item.anchor.offsetHeight; }
      const w = g.item.w, h = g.item.h;
      let y = g.y;
      for (let pass = 0; pass < 4; pass++) {
        const hit = taken.find(r => Math.abs(r.x - g.x) < (r.w + w) / 2 + 2 && y > r.y - r.h && y - h < r.y);
        if (!hit) break;
        y = hit.y - hit.h;
      }
      taken.push({ x: g.x, y, w, h });
      this.place(g.item, g.x, y);
    }
  }

  place(item, x, y) {
    const key = x + ',' + y;
    if (key !== item.last) { item.anchor.style.transform = `translate3d(${x}px, ${y}px, 0) translate(-50%, -100%)`; item.last = key; }
  }

  // MARK: 会话的名牌、气泡、工具小签

  nameTag(s) {
    const node = el('div', 'tag');
    node.innerHTML = `<i class="dot ${this.stateClass(s)}"></i><span>${esc(s.title)}</span>`;
    node.classList.toggle('pinned', s.activity === 'waiting' || s.failed);
    // 休息中（空闲、离线）的名牌半透明、垫在最底下，不跟别的牌子抢位置（10-27）
    node.classList.toggle('resting', !s.failed && s.activity !== 'busy' && s.activity !== 'waiting');
    node.addEventListener('click', () => this.world.focusSession(s.key));
    return node;
  }

  stateClass(s) {
    return s.failed ? 'error' : s.activity;
  }

  /// 头顶冒一条气泡（一个人同时只有一条，新的顶掉旧的）；过一会儿自己收起来
  bubble(key, message, { linger = 14 } = {}) {
    const s = this.world.data.sessions.get(key);
    if (!s) return;
    const old = this.bubbles.get(key);
    if (old) clearTimeout(old.timer);
    if (message.role === 'dots') {
      // 说话但没有新内容：冒个「…」
      const node = el('div', 'bubble dots', '<i></i><i></i><i></i>');
      const item = this.label('bubble:' + key, node, () => this.world.office.tagPos(key, new THREE.Vector3()), { lod: 'mid', layer: 3 });
      const entry = { node, item, at: performance.now(), timer: setTimeout(() => this.collapse(key), linger * 1000) };
      this.bubbles.set(key, entry);
      return;
    }
    const node = el('div', 'bubble ' + (message.role === 'user' ? 'user' : message.role === 'talk' ? 'talk' : 'agent'));
    const who = message.role === 'user' ? t('你') : message.role === 'talk' ? t('对「%@」说', message.to) : this.world.data.agentName(s.agent);
    const text = plain(message.text);
    const images = (message.images || []).slice(0, 3);
    node.innerHTML = `<div class="who">${esc(who)}<span>${esc(ago(message.ts))}</span></div>`
      + (text ? `<div class="text">${esc(text.length > 220 ? text.slice(0, 220) + '…' : text)}</div>` : '')
      + (images.length ? `<div class="thumbs">${images.map((img, i) => `<img data-i="${i}" src="${esc(this.world.mediaURL(key, img))}" alt="">`).join('')}</div>` : '');
    node.addEventListener('click', (e) => {
      const img = e.target.closest('img');
      if (img) { e.stopPropagation(); this.showImage(img.src); return; }
      this.world.openSession(key);
    });
    const item = this.label('bubble:' + key, node, () => this.world.office.tagPos(key, new THREE.Vector3()), { lod: 'mid', layer: 3 });
    node.classList.add('pop');
    const entry = { node, item, at: performance.now(), timer: setTimeout(() => this.collapse(key), linger * 1000) };
    this.bubbles.set(key, entry);
    // 同时最多展开 6 条，最早的先收
    const open = [...this.bubbles.entries()].filter(([, e]) => !e.compact).sort((a, b) => a[1].at - b[1].at);
    while (open.length > 6) { const [k] = open.shift(); this.collapse(k); }
  }

  /// 大气泡收起：变回头顶常驻的小气泡（最新的动作或消息）
  collapse(key) {
    const entry = this.bubbles.get(key);
    if (!entry || entry.compact) return;
    clearTimeout(entry.timer);
    entry.node.classList.add('out');
    setTimeout(() => { if (this.bubbles.get(key) === entry) this.compact(key); }, 260);
  }

  /// 头顶常驻的小气泡：在干活显示「[Bash] npm test」，等确认显示在等什么，出错显示原因，空闲显示最后一句话
  setStatus(key, status) {
    const was = this.status.get(key);
    this.status.set(key, status);
    const entry = this.bubbles.get(key);
    if (entry && !entry.compact) return;   // 正展开着大气泡：收起时再换
    if (!was || was.kind !== status.kind || was.text !== status.text || was.tool !== status.tool || !entry) this.compact(key);
  }

  compact(key) {
    const status = this.status.get(key);
    if (!status || (!status.text && !status.tool)) { this.drop('bubble:' + key); this.bubbles.delete(key); return; }
    const tag = status.kind === 'tool' ? status.tool : status.kind === 'wait' ? t('待确认') : status.kind === 'error' ? t('出错')
      : status.kind === 'think' ? t('思考') : status.kind === 'user' ? t('你') : '';
    const node = el('div', 'bubble compact ' + status.kind);
    node.innerHTML = (tag ? `<span class="tag">${esc(tag)}</span>` : '') + `<span class="text">${esc(plain(status.text || '').slice(0, 160))}</span>`;
    node.addEventListener('click', () => this.world.openSession(key));
    const item = this.label('bubble:' + key, node, () => this.world.office.tagPos(key, new THREE.Vector3()), { lod: 'mid', layer: 2 });
    this.bubbles.set(key, { node, item, at: 0, compact: true });
  }

  forget(key) {
    this.status.delete(key);
    this.bubbles.delete(key);
    this.drop('bubble:' + key);
  }

  // MARK: 左上角统计、左下角动态

  refreshStats() {
    const s = this.world.data.totals();
    const chip = (label, value, cls = '', cycle = '') =>
      `<span class="chip ${cls}" ${cycle ? `data-cycle="${cycle}" title="${esc(t('依次查看'))}"` : ''}><b>${value}</b>${esc(label)}</span>`;
    this.stats.innerHTML = [
      `<span class="title">${esc(t('世界'))}</span>`,
      chip(t('会话'), s.sessions),
      chip(t('工作中'), s.busy, s.busy ? 'busy' : '', s.busy ? 'busy' : ''),
      chip(t('待确认'), s.waiting, s.waiting ? 'waiting' : '', s.waiting ? 'waiting' : ''),
      chip(t('出错'), s.failed, s.failed ? 'error' : '', s.failed ? 'error' : ''),
      chip(t('项目'), s.projects),
      chip(t('设备在线'), `${s.online}/${s.sources}`),
    ].join('');
  }

  // MARK: 悬停卡片

  showCard(target, x, y) {
    if (!target) { this.card.hidden = true; return; }
    const d = this.world.data;
    let html = '';
    if (target.type === 'screen' || target.type === 'figure') {
      const s = d.sessions.get(target.key);
      if (!s) { this.card.hidden = true; return; }
      const state = s.failed ? t('出错') : { busy: t('工作中'), waiting: t('待确认'), idle: t('空闲') }[s.activity];
      const source = d.sources.get(s.sourceId);
      const rows = [
        [t('项目'), s.project],
        [t('设备'), (source?.name || s.sourceName) + (source && !source.online ? ' · ' + t('离线') : '')],
        ['Agent', [d.agentName(s.agent), s.model, s.effort && t(effortName(s.effort))].filter(Boolean).join(' · ')],
        s.context != null ? [t('上下文'), `<span class="meter"><i style="width:${Math.min(100, s.context)}%" class="${s.context > 85 ? 'hot' : s.context > 60 ? 'warm' : ''}"></i></span>${s.context}%`] : null,
        s.subagents ? [t('子 agent'), String(s.subagents)] : null,
        s.startedAt ? [t('开始'), ago(s.startedAt)] : null,
      ].filter(Boolean);
      html = `<div class="head"><span class="avatar">${esc(initials(s.title))}</span><div><b>${esc(s.title)}</b><span class="state ${this.stateClass(s)}">${esc(s.stage ? state + ' · ' + s.stage : state)}</span></div></div>`
        + (s.line ? `<p>${esc(plain(s.line).slice(0, 160))}</p>` : '')
        + `<dl>${rows.map(([k, val]) => `<dt>${esc(k)}</dt><dd>${k === t('上下文') ? val : esc(val)}</dd>`).join('')}</dl>`
        + `<div class="foot">${esc(target.type === 'screen' ? t('点击屏幕查看会话') : t('点击人物定位 · 点击屏幕查看会话'))}</div>`;
    } else if (target.type === 'room') {
      const label = this.world.dc.label(target.room, d);
      html = `<div class="head"><div><b>${esc(label.name)}</b><span class="state">${esc(label.sub)}</span></div></div>`
        + `<div class="foot">${esc(t('信号灯闪得越快，在工作的会话越多'))}</div>`;
    } else if (target.type === 'satellite') {
      const source = d.sources.get(target.id);
      const sys = d.sys[target.id] || {};
      const count = [...d.sessions.values()].filter(s => s.sourceId === target.id).length;
      html = `<div class="head"><div><b>${esc(source?.name || target.id)}</b><span class="state ${source?.online ? 'idle' : 'error'}">${esc(source?.online ? t('在线') : t('离线'))}</span></div></div>`
        + `<dl><dt>${esc(t('会话'))}</dt><dd>${count}</dd>`
        + (sys.cpu != null ? `<dt>CPU</dt><dd>${Math.round(sys.cpu * 100)}%</dd>` : '')
        + (sys.memTotal ? `<dt>${esc(t('内存'))}</dt><dd>${Math.round(sys.memUsed / sys.memTotal * 100)}%</dd>` : '')
        + `</dl><div class="foot">${esc(t('点击查看设备详情'))}</div>`;
    } else if (target.type === 'note') {
      const n = this.world.board.describe(target.note);
      html = `<div class="head"><div><b>${esc(n.kind === 'user' ? t('你的待办') : t('agent 的待办'))}</b><span class="state ${target.note.status === 'doing' ? 'busy' : ''}">${esc(n.state)}${n.who ? ' · ' + esc(n.who) : ''}</span></div></div>`
        + `<p>${esc(n.title)}</p>`
        + (n.progress ? `<dl><dt>${esc(t('进度'))}</dt><dd>${esc(n.progress)}</dd></dl>` : '')
        + (n.detail ? `<div class="foot">${esc(n.detail.slice(0, 120))}</div>` : '');
    } else if (target.type === 'zone') {
      const list = target.zone.sessions.map(s => d.sessions.get(s.key)).filter(Boolean);
      html = `<div class="head"><div><b>${esc(target.zone.name)}</b><span class="state">${esc(t('%@ 个会话', list.length))}</span></div></div>`
        + `<ul>${list.slice(0, 8).map(s => `<li><i class="dot ${this.stateClass(s)}"></i>${esc(s.title)}</li>`).join('')}</ul>`;
    }
    this.card.innerHTML = html;
    this.card.hidden = false;
    const w = this.card.offsetWidth, h = this.card.offsetHeight;
    const W = this.root.clientWidth, H = this.root.clientHeight;
    const left = x + 18 + w > W - 8 ? x - w - 18 : x + 18;
    const top = Math.min(Math.max(8, y - h / 2), H - h - 8);
    this.card.style.transform = `translate(${Math.round(left)}px, ${Math.round(top)}px)`;
  }

  showImage(src) {
    this.lightbox.innerHTML = '';
    const img = el('img');
    img.src = src;
    this.lightbox.appendChild(img);
    this.lightbox.hidden = false;
  }

  flashHint(text) {
    this.hint.textContent = text;
    this.hint.classList.remove('show');
    void this.hint.offsetWidth;
    this.hint.classList.add('show');
  }
}

function effortName(level) {
  return { auto: '自动', low: '低', medium: '中', high: '高', xhigh: '超高', max: '最高' }[level] || level;
}
