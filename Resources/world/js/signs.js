// 项目名写在待办墙顶上（10-27：项目名写到墙上，别飘在空中）：每个项目一块像素字牌子，贴在玻璃墙上沿下面，
// 第一行项目名（24 号像素字），第二行会话数、在工作、今日 token（12 号）。内容变了才重画；点牌子（其实点到后面的玻璃）飞到这个项目。

import * as THREE from '../vendor/three.module.min.js';
import { WALL_H, SIGN_H } from './office.js';

const H = SIGN_H;    // 牌子高（世界单位）
const PX = 32;       // 每单位多少像素：H × PX = 60，放得下 24 + 12 两行像素字（牌子放大时字跟着一起放大）

export class ZoneSigns {
  constructor(world) {
    this.world = world;
    this.signs = new Map();
    this.group = new THREE.Group();
    world.scene.add(this.group);
  }

  /// 换布局时全拆掉，refreshLabels 再按新位置建
  clear() {
    for (const sign of this.signs.values()) {
      sign.mesh.geometry.dispose();
      sign.texture.dispose();
      sign.mesh.material.dispose();
    }
    this.group.clear();
    this.signs.clear();
  }

  set(zone, name, sub) {
    let sign = this.signs.get(zone.name);
    if (!sign) {
      const w = Math.max(3, zone.w - 0.6);
      const canvas = Object.assign(document.createElement('canvas'), { width: Math.round(w * PX), height: Math.round(H * PX) });
      const texture = new THREE.CanvasTexture(canvas);
      texture.colorSpace = THREE.SRGBColorSpace;
      texture.magFilter = THREE.NearestFilter;
      texture.minFilter = THREE.LinearMipmapLinearFilter;
      const mesh = new THREE.Mesh(new THREE.PlaneGeometry(w, H), new THREE.MeshBasicMaterial({ map: texture }));
      // 贴在玻璃前面一点（玻璃前表面在 zone.z + 0.30），上沿离墙顶框 0.15
      mesh.position.set(zone.x + zone.w / 2, 0.1 + WALL_H - 0.15 - H / 2, zone.z + 0.32);
      this.group.add(mesh);
      sign = { mesh, canvas, texture, text: '' };
      this.signs.set(zone.name, sign);
    }
    const text = name + '\n' + sub;
    if (sign.text === text) return;
    sign.text = text;
    const { canvas } = sign;
    const g = canvas.getContext('2d');
    g.imageSmoothingEnabled = false;
    g.fillStyle = '#17181C';
    g.fillRect(0, 0, canvas.width, canvas.height);
    g.fillStyle = '#3A3B42';
    g.fillRect(0, canvas.height - 3, canvas.width, 3);   // 下沿一道像素边
    g.textAlign = 'center';
    g.textBaseline = 'top';
    g.fillStyle = '#F2F2F5';
    g.font = '24px "Pixel", -apple-system, "PingFang SC", sans-serif';
    g.fillText(fit(g, name, canvas.width - 24), canvas.width / 2, 6);
    g.fillStyle = '#A9ABB3';
    g.font = '12px "Pixel", -apple-system, "PingFang SC", sans-serif';
    g.fillText(fit(g, sub, canvas.width - 24), canvas.width / 2, 38);
    sign.texture.needsUpdate = true;
    this.world.invalidate?.();
  }
}

/// 太长就截断加「…」
function fit(g, text, max) {
  if (g.measureText(text).width <= max) return text;
  const chars = [...text];
  while (chars.length && g.measureText(chars.join('') + '…').width > max) chars.pop();
  return chars.join('') + '…';
}
