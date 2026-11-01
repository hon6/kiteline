// 公司的四面墙：把整个园区围起来，镜头一直在墙里面（公司内部，没有天花板，从上往下看）。
// 墙上挂红底黄字的标语横幅、黑框海报、像素挂钟（显示现在的时间），墙角摆大盆绿植；都是低分辨率画布按最近像素放大（像素风）。

import * as THREE from '../vendor/three.module.min.js';
import { mat, paint, merge } from './parts.js';
import { t } from './i18n.js';
import { WALL_H } from './office.js';
import { SCREEN_W } from './meter.js';

const HEIGHT = 14;
/// 横幅（红底黄字）：网红标语和程序员段子
const BANNERS = [
  '不要假装很努力，结果不会陪你撒谎',
  '让 agent 加班，让人类下班',
  '你只管努力，剩下的交给时间',
  '代码写得好，下班走得早',
  '今日事今日毕，今日 token 今日花',
];
/// 海报（黑框白字）
const POSTERS = ['Talk is cheap.\nShow me the code.', '能跑就别动', 'Done is better\nthan perfect.', '先跑起来\n再优化', 'Stay hungry.\nStay foolish.', '没有 bug 的代码\n是还没上线的代码'];

function pixelCanvas(w, h, draw) {
  const c = Object.assign(document.createElement('canvas'), { width: w, height: h });
  const g = c.getContext('2d');
  draw(g);
  const tex = new THREE.CanvasTexture(c);
  tex.colorSpace = THREE.SRGBColorSpace;
  tex.magFilter = THREE.NearestFilter;
  tex.minFilter = THREE.LinearFilter;
  tex.generateMipmaps = false;
  return { tex, canvas: c, g };
}

/// 横幅：按字数定宽，12 号像素字，两头一截卷边
function bannerTexture(text) {
  const g0 = document.createElement('canvas').getContext('2d');
  g0.font = '12px "Pixel", sans-serif';
  const w = Math.ceil(g0.measureText(text).width) + 28, h = 22;
  return { ...pixelCanvas(w, h, (g) => {
    g.fillStyle = '#7E1A1E'; g.fillRect(0, 0, w, h);
    g.fillStyle = '#B3262B'; g.fillRect(3, 2, w - 6, h - 4);
    g.fillStyle = '#D23A3F'; g.fillRect(3, 2, w - 6, 2);
    g.fillStyle = '#FFD86B';
    g.font = '12px "Pixel", sans-serif';
    g.textBaseline = 'middle';
    g.fillText(text, 14, h / 2 + 1);
  }), w, h };
}

function posterTexture(text) {
  const lines = text.split('\n');
  const w = 72, h = 54;
  return pixelCanvas(w, h, (g) => {
    g.fillStyle = '#E8E2D6'; g.fillRect(0, 0, w, h);
    g.fillStyle = '#18181B'; g.fillRect(3, 3, w - 6, h - 6);
    g.fillStyle = '#F2F2F2';
    g.font = '12px "Pixel", sans-serif';
    g.textAlign = 'center'; g.textBaseline = 'middle';
    lines.forEach((line, i) => g.fillText(line, w / 2, h / 2 + (i - (lines.length - 1) / 2) * 14, w - 10));
  });
}

export class Walls {
  constructor(world) {
    this.world = world;
    this.group = new THREE.Group();
    world.scene.add(this.group);
    this.clockText = '';
  }

  build(layout, palette) {
    for (const child of [...this.group.children]) {
      this.group.remove(child);
      child.geometry?.dispose();
      child.material?.map?.dispose();
      child.material?.dispose?.();
    }
    const r = layout.room;
    const w = r.maxX - r.minX, d = r.maxZ - r.minZ, cx = (r.minX + r.maxX) / 2, cz = (r.minZ + r.maxZ) / 2;
    // 墙（四面，带踢脚线和顶上一道压顶）
    const wallColor = 0x323339, trim = 0x45464D, base = 0x1E1F23;
    const parts = [];
    const side = (x, z, sx, sz) => {
      parts.push(paint(new THREE.BoxGeometry(sx, HEIGHT, sz), wallColor, mat(x, HEIGHT / 2, z)));
      parts.push(paint(new THREE.BoxGeometry(sx + 0.3, 0.5, sz + 0.3), trim, mat(x, HEIGHT + 0.25, z)));
      parts.push(paint(new THREE.BoxGeometry(sx + 0.1, 0.6, sz + 0.1), base, mat(x, 0.3, z)));
    };
    side(cx, r.minZ, w + 1, 1);      // 后墙
    side(cx, r.maxZ, w + 1, 1);      // 前墙（平时在镜头背后）
    side(r.minX, cz, 1, d + 1);      // 左墙
    side(r.maxX, cz, 1, d + 1);      // 右墙
    // 墙角的大盆绿植
    for (const [x, z] of [[r.minX + 2.2, r.minZ + 2.2], [r.maxX - 2.2, r.minZ + 2.2], [r.minX + 2.2, r.maxZ - 2.2], [r.maxX - 2.2, r.maxZ - 2.2]]) {
      parts.push(paint(new THREE.BoxGeometry(1.6, 1.4, 1.6), 0x6E5240, mat(x, 0.7, z)));
      parts.push(paint(new THREE.BoxGeometry(2.2, 2.2, 2.2), 0x3E7A4E, mat(x, 2.5, z)));
      parts.push(paint(new THREE.BoxGeometry(1.5, 1.5, 1.5), 0x4F8A5B, mat(x + 0.3, 4.0, z - 0.2)));
      parts.push(paint(new THREE.BoxGeometry(0.9, 0.9, 0.9), 0x5FA04E, mat(x - 0.2, 5.0, z + 0.1)));
    }
    const walls = new THREE.Mesh(merge(parts), new THREE.MeshLambertMaterial({ vertexColors: true }));
    this.group.add(walls);

    // 横幅、海报只挂在办公区这边（机房里面没人看，10-27）：公司墙朝外一面计量屏两边各一条，左右墙各两条，前墙一条；
    // 海报沿两侧墙挂在办公区那一段
    const slogans = BANNERS.map(t);
    const banner = (text, x, y, z, ry, scale = 0.16, room = Infinity) => {
      const { tex, w: bw, h: bh } = bannerTexture(text);
      const s = Math.min(scale, room / bw);   // 地方不够就缩小，别伸出墙外
      const mesh = new THREE.Mesh(new THREE.PlaneGeometry(bw * s, bh * s), new THREE.MeshBasicMaterial({ map: tex }));
      mesh.position.set(x, y, z);
      mesh.rotation.y = ry;
      this.group.add(mesh);
    };
    const c = layout.company;
    const front = c.z + 0.32;                       // 公司墙朝办公区的那一面
    const doorW = 3.4, doorH = 6.2, doorX = r.maxX - 0.5 - 4 - doorW / 2;
    const screenL = c.x - SCREEN_W / 2 - 1.4, screenR = c.x + SCREEN_W / 2 + 1.4;
    const leftRoom = screenL - (r.minX + 2), rightRoom = (doorX - doorW / 2 - 1.6) - screenR;
    banner(slogans[0], (r.minX + 2 + screenL) / 2, 5.2, front, 0, 0.2, leftRoom);
    banner(slogans[4], (screenR + doorX - doorW / 2 - 1.6) / 2, 5.2, front, 0, 0.2, rightRoom);
    const sideFrom = c.z + 3, sideLen = r.maxZ - 6 - sideFrom;
    banner(slogans[1], r.minX + 0.56, 11.4, sideFrom + sideLen * 0.3, Math.PI / 2);
    banner(slogans[2], r.maxX - 0.56, 11.4, sideFrom + sideLen * 0.3, -Math.PI / 2);
    banner(slogans[3], r.minX + 0.56, 11.4, sideFrom + sideLen * 0.72, Math.PI / 2);
    banner(t('欢迎来到 Kiteline'), cx, 11.4, r.maxZ - 0.56, Math.PI, 0.2);
    // 机房的门：关着的钢门，门上「机房」牌子和一盏红色指示灯
    const door = [];
    door.push(paint(new THREE.BoxGeometry(doorW + 0.6, doorH + 0.35, 0.8), 0x1E1F23, mat(doorX, (doorH + 0.35) / 2, c.z)));
    door.push(paint(new THREE.BoxGeometry(doorW, doorH, 0.84), 0x566070, mat(doorX, doorH / 2, c.z)));
    door.push(paint(new THREE.BoxGeometry(doorW - 0.5, 0.08, 0.86), 0x46505E, mat(doorX, doorH * 0.45, c.z)));
    door.push(paint(new THREE.BoxGeometry(1.5, 0.55, 0.86), 0x8FB3D0, mat(doorX, doorH * 0.76, c.z)));        // 门上一条小窗
    door.push(paint(new THREE.BoxGeometry(0.22, 0.75, 1.0), 0xC9CDD4, mat(doorX + doorW / 2 - 0.5, 3.0, c.z)));  // 把手
    door.push(paint(new THREE.BoxGeometry(0.35, 0.35, 0.9), 0xE5484D, mat(doorX + 1.65, doorH + 0.75, c.z)));    // 指示灯（牌子右边）
    this.group.add(new THREE.Mesh(merge(door), new THREE.MeshLambertMaterial({ vertexColors: true })));
    const sign = pixelCanvas(36, 14, (g) => {
      g.fillStyle = '#18181B'; g.fillRect(0, 0, 36, 14);
      g.fillStyle = '#F2F2F2'; g.font = '12px "Pixel", sans-serif';
      g.textAlign = 'center'; g.textBaseline = 'middle';
      g.fillText(t('机房'), 18, 8, 32);
    });
    const plate = new THREE.Mesh(new THREE.PlaneGeometry(2.6, 1.0), new THREE.MeshBasicMaterial({ map: sign.tex }));
    plate.position.set(doorX, doorH + 0.75, front + 0.2);
    this.group.add(plate);
    const posters = POSTERS.map(t);
    posters.forEach((text, i) => {
      const left = i % 2 === 0;
      const z = sideFrom + 2 + (Math.floor(i / 2) + 0.5) * ((sideLen - 2) / Math.ceil(posters.length / 2));
      const { tex } = posterTexture(text);
      const mesh = new THREE.Mesh(new THREE.PlaneGeometry(4.3, 3.2), new THREE.MeshBasicMaterial({ map: tex }));
      mesh.position.set(left ? r.minX + 0.56 : r.maxX - 0.56, 6.2, z);
      mesh.rotation.y = left ? Math.PI / 2 : -Math.PI / 2;
      this.group.add(mesh);
    });

    // 像素挂钟：公司墙上、计量屏正上方，显示现在几点
    this.clock = pixelCanvas(40, 16, () => {});
    const face = new THREE.Mesh(new THREE.PlaneGeometry(3.6, 1.44), new THREE.MeshBasicMaterial({ map: this.clock.tex }));
    face.position.set(c.x, WALL_H - 1.1, front + 0.12);
    const frame = new THREE.Mesh(new THREE.BoxGeometry(4.1, 1.9, 0.2), new THREE.MeshLambertMaterial({ color: 0x111215 }));
    frame.position.set(c.x, WALL_H - 1.1, front + 0.02);
    this.group.add(frame, face);
    this.clockText = '';
    this.tickClock();
  }

  tickClock() {
    if (!this.clock) return;
    const now = new Date();
    const text = String(now.getHours()).padStart(2, '0') + (now.getSeconds() % 2 ? ' ' : ':') + String(now.getMinutes()).padStart(2, '0');
    if (text === this.clockText) return;
    this.clockText = text;
    const g = this.clock.g;
    g.fillStyle = '#050505'; g.fillRect(0, 0, 40, 16);
    g.fillStyle = '#FF5A3C';
    g.font = '12px "Pixel", monospace';
    g.textAlign = 'center'; g.textBaseline = 'middle';
    g.fillText(text, 20, 9);
    this.clock.tex.needsUpdate = true;
  }

  tick() { this.tickClock(); }
}
