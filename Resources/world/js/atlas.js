// 三张图集：方块人的皮肤（每个会话一套 64×64 的像素皮肤）、像素表情（贴在脸上，跟着状态换）、
// 后背的头像牌（同侧栏的头像，用户在「Agent 详情」里换过就按换的画）。都画在一张大画布上，几十个人也只用三张贴图。

import * as THREE from '../vendor/three.module.min.js';
import { TONES, SHIRTS, PANTS, HAIR, SKIN } from './parts.js';

/// 表情：工作中专注、空闲微笑、待确认（扭头看你）惊讶、出错难过、空闲很久犯困、刚收到消息开心、说话张嘴
export const FACE = { focused: 0, smile: 1, asking: 2, sad: 3, sleepy: 4, happy: 5, talk: 6 };

/// 同一个像素位置每次抖一样的明暗（皮肤、衣服有点颗粒感，像 Minecraft 的贴图）
function shade(c, n) {
  const r = (c >> 16) & 255, g = (c >> 8) & 255, b = c & 255;
  const f = 1 + n;
  const clamp = (v) => Math.max(0, Math.min(255, Math.round(v * f)));
  return `rgb(${clamp(r)},${clamp(g)},${clamp(b)})`;
}

function noise(x, y, seed) {
  const v = Math.sin(x * 127.1 + y * 311.7 + seed * 74.7) * 43758.5453;
  return (v - Math.floor(v)) - 0.5;
}

/// 像素表情：8×8 一格（透明底，只画眼睛、眉毛、嘴），放大 16 倍、取最近像素
export function faceAtlas() {
  const px = 16, cols = 4, rows = 2;
  const c = document.createElement('canvas');
  c.width = 8 * px * cols; c.height = 8 * px * rows;
  const g = c.getContext('2d');
  const white = '#F4F4F4', iris = '#3D5FA8', dark = '#2B1D14', mouth = '#7A3E2C', red = '#B4473A';
  const dot = (index, x, y, color) => {
    g.fillStyle = color;
    g.fillRect(((index % cols) * 8 + x) * px, (Math.floor(index / cols) * 8 + y) * px, px, px);
  };
  const eyes = (i, y = 4) => { dot(i, 1, y, white); dot(i, 2, y, iris); dot(i, 5, y, iris); dot(i, 6, y, white); };
  eyes(FACE.focused); dot(FACE.focused, 1, 3, dark); dot(FACE.focused, 2, 3, dark); dot(FACE.focused, 5, 3, dark); dot(FACE.focused, 6, 3, dark);
  dot(FACE.focused, 3, 6, mouth); dot(FACE.focused, 4, 6, mouth);
  eyes(FACE.smile); dot(FACE.smile, 2, 6, mouth); dot(FACE.smile, 5, 6, mouth); dot(FACE.smile, 3, 7, mouth); dot(FACE.smile, 4, 7, mouth);
  for (const [x, y] of [[1, 3], [2, 3], [5, 3], [6, 3]]) dot(FACE.asking, x, y, white);
  eyes(FACE.asking); dot(FACE.asking, 3, 6, dark); dot(FACE.asking, 4, 6, dark); dot(FACE.asking, 3, 7, dark); dot(FACE.asking, 4, 7, dark);
  eyes(FACE.sad); dot(FACE.sad, 1, 2, dark); dot(FACE.sad, 6, 2, dark); dot(FACE.sad, 3, 6, mouth); dot(FACE.sad, 4, 6, mouth); dot(FACE.sad, 2, 7, mouth); dot(FACE.sad, 5, 7, mouth);
  for (const x of [1, 2, 5, 6]) dot(FACE.sleepy, x, 4, dark);
  dot(FACE.sleepy, 3, 6, mouth);
  dot(FACE.happy, 1, 4, dark); dot(FACE.happy, 2, 3, dark); dot(FACE.happy, 5, 3, dark); dot(FACE.happy, 6, 4, dark);
  for (const x of [2, 3, 4, 5]) dot(FACE.happy, x, 6, mouth);
  dot(FACE.happy, 3, 7, red); dot(FACE.happy, 4, 7, red);
  eyes(FACE.talk); dot(FACE.talk, 3, 6, mouth); dot(FACE.talk, 4, 6, mouth); dot(FACE.talk, 3, 7, red); dot(FACE.talk, 4, 7, red);
  const tex = new THREE.CanvasTexture(c);
  tex.colorSpace = THREE.SRGBColorSpace;
  tex.magFilter = THREE.NearestFilter;
  tex.minFilter = THREE.NearestFilter;
  tex.generateMipmaps = false;
  return { texture: tex, cell: (i) => [(i % cols) / cols, 1 - (Math.floor(i / cols) + 1) / rows, 1 / cols, 1 / rows] };
}

/// 皮肤：按 Minecraft 64×64 的展开画（头 0,0；身子 16,16；胳膊 40,16；腿 0,16），一个会话一格，满了让出最久没用的
export class SkinAtlas {
  constructor() {
    this.cols = 16; this.rows = 16;
    this.canvas = document.createElement('canvas');
    this.canvas.width = this.cols * 64; this.canvas.height = this.rows * 64;
    this.g = this.canvas.getContext('2d');
    this.texture = new THREE.CanvasTexture(this.canvas);
    this.texture.colorSpace = THREE.SRGBColorSpace;
    this.texture.magFilter = THREE.NearestFilter;
    this.texture.minFilter = THREE.NearestMipmapLinearFilter;
    this.slots = new Map();
    this.used = 0;
  }

  cellFor(key, look) {
    const sig = JSON.stringify(look);
    let slot = this.slots.get(key);
    if (!slot) {
      const index = this.used < this.cols * this.rows ? this.used++ : this.evict();
      slot = { index, sig: '' };
      this.slots.set(key, slot);
    }
    slot.at = performance.now();
    if (slot.sig !== sig) { slot.sig = sig; this.paint(slot.index, look); this.texture.needsUpdate = true; }
    return [(slot.index % this.cols) / this.cols, 1 - (Math.floor(slot.index / this.cols) + 1) / this.rows, 1 / this.cols, 1 / this.rows];
  }

  evict() {
    let oldest = null;
    for (const [key, slot] of this.slots) if (!oldest || slot.at < oldest[1].at) oldest = [key, slot];
    this.slots.delete(oldest[0]);
    return oldest[1].index;
  }

  /// look = {skin, hair, shirt, pants, style, seed}
  paint(index, look) {
    const g = this.g;
    const ox = (index % this.cols) * 64, oy = Math.floor(index / this.cols) * 64;
    const fill = (x, y, w, h, color, grain = 0.06) => {
      for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) {
        g.fillStyle = shade(color, noise(x + i, y + j, look.seed) * grain * 2);
        g.fillRect(ox + x + i, oy + y + j, 1, 1);
      }
    };
    g.clearRect(ox, oy, 64, 64);
    // 头：四周皮肤，顶上头发，两侧和后面上半截头发，前额一两排刘海
    fill(0, 0, 32, 16, look.skin, 0.04);
    fill(8, 0, 8, 8, look.hair, 0.1);                       // 头顶
    const fringe = look.style === 1 ? 1 : 2;
    fill(8, 8, 8, fringe, look.hair, 0.1);                  // 刘海
    if (look.style === 2) { fill(8, 8 + fringe, 1, 2, look.hair, 0.1); fill(15, 8 + fringe, 1, 2, look.hair, 0.1); }
    fill(0, 8, 8, 3, look.hair, 0.1); fill(16, 8, 8, 3, look.hair, 0.1);   // 两侧
    fill(24, 8, 8, look.style === 2 ? 8 : 6, look.hair, 0.1);           // 后脑勺
    if (look.style === 2) { fill(0, 11, 2, 5, look.hair, 0.1); fill(22, 11, 2, 5, look.hair, 0.1); }   // 长发垂到两侧
    // 身子：上衣，正面领口
    fill(16, 16, 24, 16, look.shirt, 0.07);
    fill(23, 20, 2, 1, look.skin, 0.03); fill(23, 21, 2, 1, shadeHex(look.shirt, -0.25), 0);
    fill(20, 30, 8, 2, shadeHex(look.shirt, -0.2), 0.05);   // 衣摆
    // 胳膊：上面四排袖子，下面是手
    fill(40, 16, 16, 16, look.shirt, 0.07);
    fill(40, 28, 16, 4, look.skin, 0.04);
    fill(48, 16, 4, 4, look.skin, 0.04);                     // 手掌（底面）
    fill(40, 24, 16, 1, shadeHex(look.shirt, -0.22), 0);     // 袖口
    // 腿：裤子 + 鞋
    fill(0, 16, 16, 16, look.pants, 0.07);
    fill(0, 29, 16, 3, 0x2E2A28, 0.08);
    fill(8, 16, 4, 4, 0x2E2A28, 0.08);
  }
}

function shadeHex(c, n) {
  const r = (c >> 16) & 255, g = (c >> 8) & 255, b = c & 255;
  const f = 1 + n;
  const k = (v) => Math.max(0, Math.min(255, Math.round(v * f)));
  return (k(r) << 16) | (k(g) << 8) | k(b);
}

/// 一个会话的长相：按 key 定（同一个会话每次打开世界都一样）；换过头像底色的，上衣跟着底色
export function lookFor(session, hash) {
  const pick = (list, salt) => list[Math.floor(hash * salt) % list.length];
  let shirt = pick(SHIRTS, 997);
  const parts = (session.face?.avatar || '').split(':');
  const toneName = parts[0] === 'text' ? parts[1] : (parts[0] === 'mark' || parts[0] === 'emoji') ? parts[2] : null;
  if (toneName && TONES[toneName]) shirt = TONES[toneName];
  return { skin: pick(SKIN, 389), hair: pick(HAIR, 593), shirt, pants: pick(PANTS, 769), style: Math.floor(hash * 131) % 3, seed: Math.floor(hash * 1000) };
}


/// 后背的头像牌：一格一个会话；满了以后最久没用的那格让出来
export class AvatarAtlas {
  constructor(mediaBase, marks, dark) {
    this.cols = 16; this.rows = 8; this.size = 128;
    this.canvas = document.createElement('canvas');
    this.canvas.width = this.cols * this.size; this.canvas.height = this.rows * this.size;
    this.g = this.canvas.getContext('2d');
    this.texture = new THREE.CanvasTexture(this.canvas);
    this.texture.colorSpace = THREE.SRGBColorSpace;
    this.texture.magFilter = THREE.NearestFilter;
    this.slots = new Map();      // key → {index, sig}
    this.mediaBase = mediaBase || '';
    this.marks = marks || {};
    this.dark = dark;
    this.used = 0;
    this.onChange = () => {};
  }

  /// 某个会话的格子（u0, v0, 宽, 高）；头像变了就重画
  cellFor(session) {
    const sig = JSON.stringify([session.title, session.face, session.agent]);
    let slot = this.slots.get(session.key);
    if (!slot) {
      let index = this.used < this.cols * this.rows ? this.used++ : this.evict();
      slot = { index, sig: '' };
      this.slots.set(session.key, slot);
    }
    slot.at = performance.now();
    if (slot.sig !== sig) { slot.sig = sig; this.paint(slot.index, session); }
    const { cols, rows } = this;
    return [(slot.index % cols) / cols, 1 - (Math.floor(slot.index / cols) + 1) / rows, 1 / cols, 1 / rows];
  }

  evict() {
    let oldest = null;
    for (const [key, slot] of this.slots) if (!oldest || slot.at < oldest[1].at) oldest = [key, slot];
    this.slots.delete(oldest[0]);
    return oldest[1].index;
  }

  /// 先画在 24×24 的小画布上（像素字、像素头像），再按最近像素放大进图集
  paint(index, session) {
    const { g, size, cols } = this;
    const x = (index % cols) * size, y = Math.floor(index / cols) * size;
    const n = 24;
    const small = this.small ??= Object.assign(document.createElement('canvas'), { width: n, height: n });
    const s = small.getContext('2d');
    s.clearRect(0, 0, n, n);
    const avatar = (session.face && session.face.avatar) || '';
    const parts = avatar.split(':');
    const tone = (name) => '#' + (TONES[name] ?? TONES.ink).toString(16).padStart(6, '0');
    const tile = (fill, edge) => { s.fillStyle = edge; s.fillRect(0, 0, n, n); s.fillStyle = fill; s.fillRect(1, 1, n - 2, n - 2); };
    const inkFor = (name) => (name === 'paper' ? '#3A3A3C' : '#FFFFFF');
    const text = (str, color, px = 12) => {
      s.fillStyle = color;
      s.font = `${px}px "Pixel", -apple-system, "PingFang SC", sans-serif`;
      s.textAlign = 'center'; s.textBaseline = 'middle';
      s.fillText(str, n / 2, n / 2 + 1, n - 2);
    };
    const commit = () => {
      g.imageSmoothingEnabled = false;
      g.clearRect(x, y, size, size);
      g.drawImage(small, 0, 0, n, n, x, y, size, size);
      this.texture.needsUpdate = true;
    };
    if (parts[0] === 'image' && parts[1]) {
      tile(tone('ink'), '#1A1A1C');
      commit();
      const img = new Image();
      img.onload = () => {
        s.imageSmoothingEnabled = true;
        s.drawImage(img, 1, 1, n - 2, n - 2);   // 缩成 22×22：像素头像
        commit();
        this.onChange();
      };
      img.src = this.mediaBase + 'api/agent-avatar?id=' + encodeURIComponent(parts[1]) + (this.suffix || '');
      return;
    } else if (parts[0] === 'emoji' && parts[1]) {
      tile(tone(parts[2]), '#1A1A1C'); text(parts[1], '#000', 16);
    } else if (parts[0] === 'text') {
      tile(tone(parts[1]), '#1A1A1C'); text(initials(session.face.name || session.title), inkFor(parts[1]));
    } else if (parts[0] === 'mark' && parts[1]) {
      tile(tone(parts[2]), '#1A1A1C'); this.mark(s, parts[1], inkFor(parts[2]));
    } else {
      // 没换过：同侧栏，淡主题色底 + 主题色的首字
      tile('#3A2A24', '#D97757'); text(initials(session.title), '#E08A6C');
    }
    commit();
  }

  mark(s, id, color) {
    const layers = this.marks[id];
    if (!layers || !layers.length || typeof Path2D === 'undefined') return;
    s.save();
    s.translate(4, 4);
    s.scale(16 / 24, 16 / 24);
    s.fillStyle = color;
    for (const layer of layers) { s.globalAlpha = layer.opacity ?? 1; s.fill(new Path2D(layer.d), 'evenodd'); }
    s.restore();
  }
}

/// 首字（同 Mac 的 SessionAvatar：英文取两个字母大写，中文取第一个字）
export function initials(title) {
  const text = (title || '').trim();
  if (!text) return '?';
  const first = text[0];
  if (/[A-Za-z0-9]/.test(first)) return text.replace(/[^A-Za-z0-9]/g, '').slice(0, 2).toUpperCase();
  return Array.from(text)[0];
}

