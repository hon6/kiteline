// 小组墙上的待办便签：每个项目玻璃墙的左半边贴着这个项目的待办（agent 自己的黄色、要你做的橙色），像素字。
// agent 记了一条待办：起身拿着便签走到墙边贴上去；开始做：走到墙边把那张撕下来拿回工位，贴在显示器旁边；
// 做完：显示器旁的便签打个勾飞走。人正在和别人聊天、走不开时，便签直接出现在该在的地方。

import * as THREE from '../vendor/three.module.min.js';
import { decalMaterial, SCREEN } from './parts.js';
import { WALL_H, SIGN_H } from './office.js';
import { t } from './i18n.js';

const NOTE_W = 0.92, NOTE_H = 0.92 * 60 / 72;   // 和便签小图一样 72 × 60
const COLORS = { agent: '#F2D35B', user: '#F4A26B' };
const v = new THREE.Vector3(), q = new THREE.Quaternion(), s = new THREE.Vector3(), m = new THREE.Matrix4(), e = new THREE.Euler();
const ease = (u) => u * u * (3 - 2 * u);

/// 便签图集：一张 72×60 的像素小图一格（12 号像素字一行五六个字、四行），放大两倍进图集（最近像素）
class NoteAtlas {
  constructor() {
    this.cw = 144; this.ch = 120; this.cols = 10; this.rows = 12;
    this.canvas = Object.assign(document.createElement('canvas'), { width: this.cw * this.cols, height: this.ch * this.rows });
    this.g = this.canvas.getContext('2d');
    this.small = Object.assign(document.createElement('canvas'), { width: 72, height: 60 });
    this.texture = new THREE.CanvasTexture(this.canvas);
    this.texture.colorSpace = THREE.SRGBColorSpace;
    this.texture.magFilter = THREE.NearestFilter;
    this.free = Array.from({ length: this.cols * this.rows }, (_, i) => i);
  }

  take() { return this.free.length ? this.free.shift() : 0; }
  give(i) { if (i != null && !this.free.includes(i)) this.free.push(i); }

  cell(i) { return [(i % this.cols) / this.cols, 1 - (Math.floor(i / this.cols) + 1) / this.rows, 1 / this.cols, 1 / this.rows]; }

  paint(i, note) {
    const g = this.small.getContext('2d');
    const color = COLORS[note.kind] || COLORS.agent;
    g.clearRect(0, 0, 72, 60);
    g.fillStyle = color; g.fillRect(0, 0, 72, 60);
    g.fillStyle = 'rgba(0,0,0,0.12)'; g.fillRect(0, 0, 72, 4);          // 顶上的胶条
    g.fillStyle = 'rgba(0,0,0,0.18)'; g.fillRect(70, 2, 2, 58); g.fillRect(2, 58, 70, 2);   // 右下一点阴影边
    g.fillStyle = '#3A2E10';
    g.font = '12px "Pixel", -apple-system, "PingFang SC", sans-serif';
    g.textBaseline = 'top';
    // 按字宽折行，最多四行
    const chars = [...(note.text || '').replace(/\s+/g, ' ')];
    const lines = [];
    let line = '';
    for (const ch of chars) {
      if (g.measureText(line + ch).width > 66) { lines.push(line); line = ch; if (lines.length === 4) break; } else line += ch;
    }
    if (lines.length < 4 && line) lines.push(line);
    if (lines.length === 4 && chars.join('').length > lines.join('').length) lines[3] = lines[3].slice(0, -1) + '…';
    lines.forEach((text, k) => g.fillText(text, 3, 6 + k * 13));
    if (note.done) {
      // 做完：大大的勾
      g.fillStyle = '#2E8B4E';
      for (const [x, y] of [[14, 22], [16, 24], [18, 26], [20, 28], [22, 26], [24, 24], [26, 22], [28, 20], [30, 18], [32, 16], [34, 14]]) g.fillRect(x * 1.5, y * 1.4, 4, 4);
    }
    const big = this.g;
    big.imageSmoothingEnabled = false;
    const x = (i % this.cols) * this.cw, y = Math.floor(i / this.cols) * this.ch;
    big.clearRect(x, y, this.cw, this.ch);
    big.drawImage(this.small, 0, 0, 72, 60, x, y, this.cw, this.ch);
    this.texture.needsUpdate = true;
  }
}

export class Board {
  constructor(world) {
    this.world = world;
    this.atlas = new NoteAtlas();
    this.notes = new Map();
    this.errands = new Map();   // 会话 key → 正在跑的差事
    this.capacity = 0;
  }

  /// 墙上第 index 个位置（玻璃墙左边约六成，右边挂图；顶上是项目名牌子）：一行三张，从上往下一行行贴；
  /// 便签按这面墙的宽放大（s 倍，最多 2.4），远远也看得出上面写的字（10-27）；整面贴满了再错开叠一层
  wallSlot(zone, index) {
    const gap = 0.22, left = zone.x + 0.6, avail = zone.w * 0.58 - 0.8;
    const size = Math.min(2.4, Math.max(1.2, (avail - gap * 2) / 3 / NOTE_W));
    const w = NOTE_W * size, h = NOTE_H * size;
    const top = WALL_H - 0.4 - SIGN_H - h / 2, bottom = 0.6 + h / 2;   // 牌子下面空一点开始贴
    const rows = Math.max(1, Math.floor((top - bottom) / (h + gap)) + 1);
    const per = 3 * rows;
    const k = index % per, layer = Math.floor(index / per);
    const col = k % 3, row = Math.floor(k / 3);
    return { x: left + w / 2 + col * (w + gap) + layer * 0.18, y: top - row * (h + gap) - layer * 0.12, z: zone.z + 0.34 + layer * 0.01, s: size };
  }

  /// 显示器旁边第 index 张（在做的事）
  deskSlot(key, index) {
    const f = this.world.office.fig(key);
    if (!f) return null;
    return { x: f.x - SCREEN.w / 2 - 0.45, y: SCREEN.y + 0.35 - index * 0.85, z: f.z + SCREEN.z + 0.12 };
  }

  ensureMesh() {
    const need = Math.max(32, this.notes.size + 8);
    if (this.mesh && this.capacity >= need) return;
    if (this.mesh) { this.world.scene.remove(this.mesh); this.mesh.geometry.dispose(); }
    this.capacity = need * 2;
    const geo = new THREE.PlaneGeometry(NOTE_W, NOTE_H);
    this.cells = new THREE.InstancedBufferAttribute(new Float32Array(this.capacity * 4), 4);
    geo.setAttribute('aCell', this.cells);
    this.material ??= Object.assign(decalMaterial(this.atlas.texture), { side: THREE.DoubleSide });
    this.mesh = new THREE.InstancedMesh(geo, this.material, this.capacity);
    this.mesh.frustumCulled = false;
    this.mesh.count = 0;
    this.world.scene.add(this.mesh);
  }

  /// 待办整份来了：新的、变了状态的、没了的
  apply(items, initial) {
    const d = this.world.data;
    const seen = new Set();
    for (const item of items || []) {
      if (!item || !item.id || !(item.agent || item.forUser)) continue;
      const owner = item.handler?.key || item.source?.key;
      const status = item.done ? 'done' : (item.status === 'doing' ? 'doing' : 'pending');
      let note = this.notes.get(item.id);
      if (!note && status === 'done') continue;   // 早就做完的不贴
      const session = d.sessions.get(owner) || d.sessions.get(item.source?.key);
      if (!note && !session) continue;            // 认不出是哪个项目的
      seen.add(item.id);
      if (!note) {
        note = { id: item.id, kind: item.forUser ? 'user' : 'agent', text: item.text, project: session.project, status, owner,
          cell: this.atlas.take(), where: null, pos: new THREE.Vector3(), yaw: 0, tilt: (Math.random() - 0.5) * 0.12, scale: 1, born: this.world.time };
        this.notes.set(item.id, note);
        this.atlas.paint(note.cell, note);
        this.arrive(note, initial, item.source?.key);
      } else {
        const was = note.status;
        note.status = status;
        note.owner = owner || note.owner;
        if (note.text !== item.text) { note.text = item.text; this.atlas.paint(note.cell, note); }
        if (was !== 'doing' && status === 'doing') this.take(note, initial);
        if (status === 'done' && was !== 'done') this.finish(note);
        if (was === 'doing' && status === 'pending') this.place(note, 'wall');
      }
      note.detail = item.detail || ''; note.progress = item.progress || ''; note.handler = item.handler?.title || '';
    }
    for (const note of this.notes.values()) if (!seen.has(note.id) && note.where !== 'leaving') this.finish(note);
    this.ensureMesh();
    this.relayout();
  }

  /// 新便签：记的人走过去贴上墙；人不在、走不开，直接贴上
  arrive(note, initial, writer) {
    if (note.status === 'doing') { this.place(note, 'desk'); return; }
    if (initial || !this.free(writer)) { this.place(note, 'wall', !initial); return; }
    note.where = 'hand';
    note.carrier = writer;
    this.errands.set(writer, { type: 'post', note, phase: 'go', at: this.world.time });
  }

  /// 开始做：处理的人走到墙边撕下来拿回工位
  take(note, initial) {
    if (initial || note.where !== 'wall' || !this.free(note.owner)) { this.place(note, 'desk', !initial); return; }
    this.errands.set(note.owner, { type: 'take', note, phase: 'go', at: this.world.time });
  }

  finish(note) {
    note.done = true;
    this.atlas.paint(note.cell, note);
    note.where = 'leaving';
    note.leaveAt = this.world.time;
  }

  free(key) {
    const office = this.world.office;
    return !!key && office.has(key) && office.fig(key).m.phase === 'seated' && !this.world.social?.busy(key) && !this.errands.has(key);
  }

  /// 人被叫去聊天了：手上的差事直接办完
  cancel(key) {
    const errand = this.errands.get(key);
    if (!errand) return;
    this.errands.delete(key);
    this.place(errand.note, errand.type === 'post' ? 'wall' : 'desk');
  }

  place(note, where, pop = false) {
    note.where = where;
    note.carrier = null;
    note.popAt = pop ? this.world.time : -10;
    this.relayout();
  }

  /// 每个便签该在的位置（墙上按项目排、桌上按人排）
  relayout() {
    const layout = this.world.layout;
    if (!layout) return;
    const wall = new Map(), desk = new Map();
    const list = [...this.notes.values()].sort((a, b) => a.born - b.born);
    for (const note of list) {
      if (note.where === 'wall') {
        const zone = layout.zones.find(z => z.name === note.project);
        if (!zone) { note.home = null; continue; }
        const n = wall.get(zone.name) || 0; wall.set(zone.name, n + 1);
        note.home = this.wallSlot(zone, n);
        note.homeYaw = 0;
      } else if (note.where === 'desk') {
        const n = desk.get(note.owner) || 0; desk.set(note.owner, n + 1);
        note.home = this.deskSlot(note.owner, n);
        note.homeYaw = 0;
      }
    }
  }

  /// 墙上留给新便签的位置（贴之前就知道走去哪）
  nextWallSlot(note) {
    const zone = this.world.layout?.zones.find(z => z.name === note.project);
    if (!zone) return null;
    const count = [...this.notes.values()].filter(n => n !== note && n.project === note.project && n.where === 'wall').length;
    return this.wallSlot(zone, count);
  }

  tick(time, dt) {
    if (!this.mesh) return;
    const office = this.world.office;
    // 差事：起身 → 走到墙边 → 伸手贴 / 撕 → 走回去坐下
    for (const [key, errand] of [...this.errands]) {
      const note = errand.note;
      if (!office.has(key)) { this.errands.delete(key); this.place(note, errand.type === 'post' ? 'wall' : 'desk'); continue; }
      const slot = errand.type === 'post' ? (errand.slot ??= this.nextWallSlot(note)) : note.home;
      if (!slot) { this.errands.delete(key); this.place(note, errand.type === 'post' ? 'wall' : 'desk'); continue; }
      if (errand.phase === 'go') {
        office.wantStand(key, { x: slot.x, z: slot.z + 1.25 });
        if (office.arrived(key)) { errand.phase = 'reach'; errand.at = time; office.face(key, 0); office.gesture(key, 'reach'); }
        else if (time - errand.at > 25) errand.phase = 'reach';
      } else if (errand.phase === 'reach') {
        if (time - errand.at > 0.45 && !errand.swapped) {
          errand.swapped = true;
          if (errand.type === 'post') { this.place(note, 'wall', true); }
          else { note.where = 'hand'; note.carrier = key; }
        }
        if (time - errand.at > 0.9) { errand.phase = 'back'; office.gesture(key, null); office.wantSit(key); }
      } else if (errand.phase === 'back') {
        if (office.fig(key).m.phase === 'seated') {
          this.errands.delete(key);
          if (errand.type === 'take') this.place(note, 'desk', false);
        }
      }
    }
    // 谁手里拿着便签（胳膊端着）
    for (const f of office.figures) f.carrying = false;
    for (const note of this.notes.values()) if (note.where === 'hand' && note.carrier) { const f = office.fig(note.carrier); if (f) f.carrying = true; }
    // 摆便签
    let n = 0;
    for (const note of [...this.notes.values()]) {
      let target = note.home, yaw = 0;
      // 墙上的按那面墙放大，拿在手里、贴在显示器旁的照原样大；换地方时慢慢变（刚出现的直接到位）
      const want = note.where === 'wall' && note.home?.s ? note.home.s : 1;
      note.scale = note.pos.lengthSq() ? note.scale + (want - note.scale) * (1 - Math.exp(-dt * 8)) : want;
      let scale = note.scale;
      if (note.where === 'hand' && note.carrier) {
        const hand = office.handPos(note.carrier, v);
        if (hand) { target = { x: hand.x, y: hand.y, z: hand.z }; yaw = office.fig(note.carrier).m.yaw + Math.PI; }
        note.pos.set(target.x, target.y, target.z);
      } else if (target) {
        // 往该在的位置飞过去（贴墙、回桌）
        const k = 1 - Math.exp(-dt * 10);
        note.pos.x += (target.x - note.pos.x) * (note.pos.lengthSq() ? k : 1);
        note.pos.y += (target.y - note.pos.y) * (note.pos.lengthSq() ? k : 1);
        note.pos.z += (target.z - note.pos.z) * (note.pos.lengthSq() ? k : 1);
      }
      if (note.where === 'leaving') {
        const u = Math.min(1, (time - note.leaveAt) / 1.4);
        if (u >= 1) { this.notes.delete(note.id); this.atlas.give(note.cell); continue; }
        note.pos.y += dt * 1.6 * ease(u);
        scale = 1 - ease(Math.max(0, u - 0.4) / 0.6);
      }
      const pop = time - (note.popAt ?? -10);
      if (pop >= 0 && pop < 0.35) scale *= 0.6 + 0.4 * ease(pop / 0.35) + Math.sin(pop / 0.35 * Math.PI) * 0.15;
      if (!target && note.where !== 'hand' && note.where !== 'leaving') continue;
      const wobble = note.where === 'hand' ? Math.sin(time * 9) * 0.06 : 0;
      m.compose(note.pos, q.setFromEuler(e.set(0, yaw, note.tilt + wobble)), s.setScalar(scale));
      this.mesh.setMatrixAt(n, m);
      this.cells.setXYZW(n, ...this.atlas.cell(note.cell));
      note.instance = n;
      n++;
    }
    this.mesh.count = n;
    this.mesh.instanceMatrix.needsUpdate = true;
    this.cells.needsUpdate = true;
  }

  pick(raycaster) {
    if (!this.mesh || !this.mesh.count) return null;
    const hit = raycaster.intersectObject(this.mesh, false).find(h => h.instanceId != null);
    if (!hit) return null;
    return [...this.notes.values()].find(n => n.instance === hit.instanceId) || null;
  }

  /// 悬停卡片里的几行
  describe(note) {
    const state = note.done ? t('已完成') : note.status === 'doing' ? t('进行中') : t('待处理');
    return { title: note.text, state, who: note.handler, progress: note.progress, detail: note.detail, kind: note.kind };
  }
}
