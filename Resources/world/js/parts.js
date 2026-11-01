// 零件：几何体、材质、着色器。
// 性能要点：同一种东西（工位、小人的头、手臂、机柜、信号灯……）都用 InstancedMesh 一次画完，几十个会话也只有几十次绘制；
// 静态的零件按颜色写进顶点颜色合成一个几何体；屏幕方块、信号灯闪烁全在着色器里按时间算，不传贴图、不逐帧改数据。

import * as THREE from '../vendor/three.module.min.js';
import { mergeGeometries } from '../vendor/addons/utils/BufferGeometryUtils.js';

const _m = new THREE.Matrix4(), _q = new THREE.Quaternion(), _e = new THREE.Euler(), _p = new THREE.Vector3(), _s = new THREE.Vector3();

export function mat(x = 0, y = 0, z = 0, rx = 0, ry = 0, rz = 0, sx = 1, sy = 1, sz = 1) {
  return new THREE.Matrix4().compose(_p.set(x, y, z), _q.setFromEuler(_e.set(rx, ry, rz)), _s.set(sx, sy, sz));
}

/// 上好顶点颜色的零件（去掉 uv、统一成非索引，才能合并）
export function paint(geometry, hex, matrix) {
  let g = geometry.index ? geometry.toNonIndexed() : geometry.clone();
  geometry.dispose();
  if (g.attributes.uv) g.deleteAttribute('uv');
  if (matrix) g.applyMatrix4(matrix);
  const c = new THREE.Color(hex);
  const n = g.attributes.position.count;
  const colors = new Float32Array(n * 3);
  for (let i = 0; i < n; i++) { colors[i * 3] = c.r; colors[i * 3 + 1] = c.g; colors[i * 3 + 2] = c.b; }
  g.setAttribute('color', new THREE.BufferAttribute(colors, 3));
  return g;
}

export function merge(list) {
  const g = mergeGeometries(list, false);
  for (const item of list) item.dispose();
  g.computeBoundingSphere();
  return g;
}

const box = (w, h, d) => new THREE.BoxGeometry(w, h, d);
const cyl = (rt, rb, h, seg = 12) => new THREE.CylinderGeometry(rt, rb, h, seg);

// MARK: - 配色（整个世界是深灰色的画布，浅白色格线；不跟系统深浅色走）

/// 头像底色（同 KitelineKit/Views/AgentDetails.swift 的 FaceTone），也是小人上衣的颜色
export const TONES = {
  brand: 0xD97757, ink: 0x3A3A3C, slate: 0x5B6878, sky: 0x4C7FA8, sage: 0x6A8A70,
  sand: 0xA8875A, rust: 0xA9614A, plum: 0x7A6488, paper: 0xECE9E3,
};
export const SHIRTS = [TONES.brand, TONES.slate, TONES.sky, TONES.sage, TONES.sand, TONES.rust, TONES.plum, TONES.ink];
export const PANTS = [0x2E3A57, 0x3A3F47, 0x24324A, 0x5A4A3A, 0x2E2E30, 0x3D4F3A];
export const HAIR = [0x3B2414, 0x1C1410, 0x6B4A2B, 0xB98B4E, 0x8C8C8C, 0x7A3A1E];
export const SKIN = [0xC99572, 0xE0AC85, 0xA8714E, 0xF1C7A3, 0x8D5A3B];

export function palette() {
  return {
    canvas: 0x2A2B2F, grid: 0xFFFFFF, gridMinor: 0.07, gridMajor: 0.16,
    deskTop: 0x5A5048, deskLeg: 0x26262A, keyboard: 0x161618, bezel: 0x101012, stool: 0x232326, stoolSeat: 0x3A3B3F,
    carpets: [0x343A44, 0x35403A, 0x423C33, 0x3C3542, 0x333E48, 0x443B35, 0x3A3A40],
    glass: 0x9AA3B2, glassOpacity: 0.75,   // 待办墙：10-27 觉得太透（原来白色 0.07），两次各把透明度减半（0.5 → 0.75）、偏灰，便签看得清
    rail: 0x4A4B52,
    platform: 0x34373E, rack: 0x16181C, unit: 0x24272D, unitFace: 0x2E323A, dish: 0xC4C7CD,
    hemiSky: 0xC8CEDA, hemiGround: 0x2A2622, hemi: 1.35, sun: 1.7, sunColor: 0xFFF3E2,
    shadow: 0.5, plant: 0x4F8A5B, pot: 0x7A6250, mug: 0xE8E2D6,
  };
}

// MARK: - 工位（桌子、键盘、显示器、凳子合成一个几何体；人坐在原点，面朝 -z）

export const SCREEN = { w: 2.8, h: 1.62, y: 4.25, z: -2.62 };

export function workstationGeometry(p) {
  const parts = [
    paint(box(5.2, 0.18, 2.6), p.deskTop, mat(0, 2.45, -1.95)),
    paint(box(5.0, 0.05, 2.4), p.deskLeg, mat(0, 2.28, -1.95)),
    ...[[-2.45, -0.8], [2.45, -0.8], [-2.45, -3.1], [2.45, -3.1]].map(([x, z]) => paint(box(0.16, 2.36, 0.16), p.deskLeg, mat(x, 1.18, z))),
    paint(box(1.9, 0.08, 0.62), p.keyboard, mat(0, 2.58, -1.05)),
    paint(box(0.3, 0.09, 0.42), p.keyboard, mat(1.35, 2.58, -1.05)),          // 鼠标
    paint(box(0.95, 0.06, 0.62), p.bezel, mat(0, 2.57, -2.62)),              // 显示器底座
    paint(box(0.16, 0.95, 0.12), p.bezel, mat(0, 3.0, -2.72)),
    paint(box(SCREEN.w + 0.2, SCREEN.h + 0.2, 0.14), p.bezel, mat(0, SCREEN.y, -2.72)),
    paint(box(1.3, 0.22, 1.3), p.stoolSeat, mat(0, 1.41, 0.05)),            // 方凳（不挡后背的印花；凳面比坐着的腿底低一点，免得两个面重在一起闪）
    paint(box(0.36, 1.33, 0.36), p.stool, mat(0, 0.67, 0.05)),
    paint(box(1.1, 0.14, 1.1), p.stool, mat(0, 0.07, 0.05)),
  ];
  return merge(parts);
}

/// 桌上的小摆设：绿植、杯子（按会话随机给，热闹一点）
export function plantGeometry(p) {
  return merge([
    paint(box(0.5, 0.42, 0.5), p.pot, mat(0, 0.21, 0)),
    paint(box(0.7, 0.7, 0.7), p.plant, mat(0, 0.78, 0)),
    paint(box(0.4, 0.4, 0.4), 0x5FA04E, mat(0.12, 1.25, -0.05)),
  ]);
}

export function mugGeometry(p) {
  return merge([
    paint(box(0.32, 0.36, 0.32), p.mug, mat(0, 0.18, 0)),
    paint(box(0.1, 0.2, 0.08), p.mug, mat(0.21, 0.2, 0)),
    paint(box(0.24, 0.02, 0.24), 0x3B2A20, mat(0, 0.375, 0)),
  ]);
}

// MARK: - 我的世界风格的方块人（坐姿；头、身子、两条胳膊、两条腿各一组实例，贴同一张皮肤图集）

/// 一个像素多大（世界单位）：头 8×8×8、身子 8×12×4、胳膊和腿 4×12×4，同 Minecraft
export const PX = 0.13;
export const FIG = {
  hip: 1.81,                         // 坐在凳子上：腿平伸，胯（身子底）这么高
  body: { w: 8 * PX, h: 12 * PX, d: 4 * PX },
  head: 8 * PX,
  shoulder: { x: 6 * PX, y: 10 * PX },   // 相对胯：肩膀转轴（胳膊顶往下 2 像素）
  leg: { x: 2 * PX },
  limb: 12 * PX,
};

/// 带皮肤贴图坐标的方块：按 Minecraft 皮肤（64×64）的展开方式取各面（ox, oy 是这一块在皮肤上的左上角）。
/// 面的顺序同 BoxGeometry：+x（人的右边，人朝 -z）、-x、+y、-y、+z（后背）、-z（正面）
function skinBox(w, h, d, ox, oy) {
  const g = new THREE.BoxGeometry(w * PX, h * PX, d * PX);
  const rects = [
    [ox, oy + d, d, h], [ox + d + w, oy + d, d, h],
    [ox + d, oy, w, d], [ox + d + w, oy, w, d],
    [ox + d + w + d, oy + d, w, h], [ox + d, oy + d, w, h],
  ];
  const uv = g.attributes.uv;
  const e = 0.03;   // 往里收一点，免得采到隔壁一块
  for (let f = 0; f < 6; f++) {
    const [rx, ry, rw, rh] = rects[f];
    for (let k = 0; k < 4; k++) {
      const i = f * 4 + k;
      const u = uv.getX(i), v = uv.getY(i);
      uv.setXY(i, (rx + e + u * (rw - 2 * e)) / 64, 1 - (ry + e + (1 - v) * (rh - 2 * e)) / 64);
    }
  }
  return g;
}

/// 头：原点在脖子（头底面中心）
export function headGeometry() { return skinBox(8, 8, 8, 0, 0).translate(0, 4 * PX, 0); }
/// 身子：原点在胯（底面中心）
export function bodyGeometry() { return skinBox(8, 12, 4, 16, 16).translate(0, 6 * PX, 0); }
/// 胳膊：原点在肩膀转轴（顶下 2 像素），朝下长
export function armGeometry() { return skinBox(4, 12, 4, 40, 16).translate(0, -4 * PX, 0); }
/// 腿：原点在胯，朝下长（坐着时整条转到前面去）
export function legGeometry() { return skinBox(4, 12, 4, 0, 16).translate(0, -6 * PX, 0); }

/// 等你确认 / 出错：显示器旁边转着的方块标记
export function markerGeometry() {
  return new THREE.OctahedronGeometry(0.42, 0).scale(0.75, 1.15, 0.75);
}

/// 皮肤材质：Lambert 光照 + 每个实例从图集里取自己那一格（aCell = u0, v0, 宽, 高）
export function skinMaterial(map) {
  const material = new THREE.MeshLambertMaterial({ map });
  material.onBeforeCompile = (shader) => {
    shader.vertexShader = 'attribute vec4 aCell;\n' + shader.vertexShader.replace('#include <uv_vertex>',
      '#include <uv_vertex>\n  vMapUv = aCell.xy + vMapUv * aCell.zw;');
  };
  material.customProgramCacheKey = () => 'skin-atlas';
  return material;
}

function mergeKeepUV(list) {
  const normalized = list.map(g => {
    const n = g.index ? g.toNonIndexed() : g;
    if (!n.attributes.uv) n.setAttribute('uv', new THREE.BufferAttribute(new Float32Array(n.attributes.position.count * 2), 2));
    return n;
  });
  const g = mergeGeometries(normalized, false);
  g.computeBoundingSphere();
  return g;
}

// MARK: - 机房

export const RACK = { w: 2.5, h: 8.2, d: 2.3, units: 12, unitH: 0.52, base: 0.6 };

export function rackGeometry(p) {
  const parts = [
    paint(box(RACK.w, RACK.h, RACK.d), p.rack, mat(0, RACK.h / 2, 0)),
    paint(box(RACK.w + 0.12, 0.16, RACK.d + 0.12), p.rail, mat(0, RACK.h + 0.08, 0)),
    paint(box(RACK.w - 0.2, 0.08, 0.06), p.rail, mat(0, RACK.h - 0.35, RACK.d / 2 + 0.03)),
  ];
  for (let u = 0; u < RACK.units; u++) {
    const y = RACK.base + u * RACK.unitH * 1.18 + RACK.unitH / 2;
    parts.push(paint(box(RACK.w - 0.3, RACK.unitH, 0.12), u % 3 === 1 ? p.unitFace : p.unit, mat(0, y, RACK.d / 2 + 0.04)));
    // 把手
    parts.push(paint(box(0.06, RACK.unitH * 0.6, 0.06), p.rail, mat(-RACK.w / 2 + 0.28, y, RACK.d / 2 + 0.13)));
  }
  return merge(parts);
}

/// 信号灯在机柜正面的位置（相对机柜原点）：每层右边一排小灯 + 左边一个状态灯，顶上一个红色航标灯
export function rackLedSlots() {
  const slots = [];
  for (let u = 0; u < RACK.units; u++) {
    const y = RACK.base + u * RACK.unitH * 1.18 + RACK.unitH / 2;
    for (let k = 0; k < 6; k++) slots.push({ x: 0.15 + k * 0.17, y: y + (k % 2 ? 0.08 : -0.08), z: RACK.d / 2 + 0.11, kind: 'activity' });
    slots.push({ x: -0.55, y, z: RACK.d / 2 + 0.11, kind: 'status' });
  }
  slots.push({ x: 0, y: RACK.h + 0.25, z: 0, kind: 'beacon' });
  return slots;
}

/// 卫星天线：底座 + 叉架 + 抛物面 + 馈源；原点在底座中心，天线面朝 +z（转 yaw 对准卫星）
export function dishGeometry(p) {
  const bowl = [];
  for (let i = 0; i <= 10; i++) { const r = i * 0.17; bowl.push(new THREE.Vector2(r, r * r * 0.18)); }
  const dish = new THREE.LatheGeometry(bowl, 22);
  dish.rotateX(-Math.PI / 2 + 0.7);   // 抬头 50 度左右
  return merge([
    paint(cyl(0.7, 0.9, 0.5, 14), p.rail, mat(0, 0.25, 0)),
    paint(cyl(0.22, 0.28, 2.2, 10), p.dish, mat(0, 1.6, 0)),
    paint(box(1.0, 0.3, 0.5), p.rail, mat(0, 2.7, 0)),
    paint(dish, p.dish, mat(0, 3.1, 0.2)),
    paint(cyl(0.05, 0.05, 1.5, 6), p.rail, mat(0, 3.75, 0.85, 0.85, 0, 0)),
    paint(cyl(0.16, 0.08, 0.3, 8), p.rail, mat(0, 4.25, 1.4, 0.85, 0, 0)),
  ]);
}
/// 天线馈源相对底座的位置（光弧从这里出发）
export const DISH_FEED = new THREE.Vector3(0, 4.3, 1.4);

// MARK: - 卫星

export function satelliteBodyGeometry() {
  const gold = 0xC9A24A, dark = 0x2A2D33, white = 0xE8E8EA;
  const bowl = [];
  for (let i = 0; i <= 8; i++) { const r = i * 0.09; bowl.push(new THREE.Vector2(r, r * r * 0.9)); }
  return merge([
    paint(box(1.6, 1.3, 1.3), gold, mat(0, 0, 0)),
    paint(box(1.64, 0.12, 1.34), dark, mat(0, 0.6, 0)),
    paint(box(1.64, 0.12, 1.34), dark, mat(0, -0.6, 0)),
    paint(cyl(0.05, 0.05, 1.4, 6), white, mat(-1.45, 0, 0, 0, 0, Math.PI / 2)),
    paint(cyl(0.05, 0.05, 1.4, 6), white, mat(1.45, 0, 0, 0, 0, Math.PI / 2)),
    paint(new THREE.LatheGeometry(bowl, 16), white, mat(0, -0.75, 0, Math.PI, 0, 0)),
    paint(cyl(0.03, 0.03, 0.9, 5), white, mat(0.45, 1.05, 0.3)),
    paint(new THREE.SphereGeometry(0.08, 6, 4), white, mat(0.45, 1.5, 0.3)),
  ]);
}

/// 太阳能板（两片，带格子贴图）
export function solarPanelGeometry() {
  const left = new THREE.BoxGeometry(3.2, 0.05, 1.25).translate(-3.75, 0, 0);
  const right = new THREE.BoxGeometry(3.2, 0.05, 1.25).translate(3.75, 0, 0);
  return mergeGeometries([left, right], false);
}

export function solarPanelTexture() {
  const c = document.createElement('canvas');
  c.width = 256; c.height = 128;
  const g = c.getContext('2d');
  g.fillStyle = '#1B2A44'; g.fillRect(0, 0, 256, 128);
  g.strokeStyle = '#3B5A86'; g.lineWidth = 2;
  for (let x = 0; x <= 256; x += 32) { g.beginPath(); g.moveTo(x, 0); g.lineTo(x, 128); g.stroke(); }
  for (let y = 0; y <= 128; y += 32) { g.beginPath(); g.moveTo(0, y); g.lineTo(256, y); g.stroke(); }
  const tex = new THREE.CanvasTexture(c);
  tex.colorSpace = THREE.SRGBColorSpace;
  return tex;
}

// MARK: - 贴图

/// 圆形渐变：光晕、软阴影共用
export function radialTexture(inner = 'rgba(255,255,255,1)', outer = 'rgba(255,255,255,0)') {
  const c = document.createElement('canvas');
  c.width = c.height = 128;
  const g = c.getContext('2d');
  const grad = g.createRadialGradient(64, 64, 0, 64, 64, 64);
  grad.addColorStop(0, inner);
  grad.addColorStop(0.35, inner.replace(/[\d.]+\)$/, '0.55)'));
  grad.addColorStop(1, outer);
  g.fillStyle = grad;
  g.fillRect(0, 0, 128, 128);
  const tex = new THREE.CanvasTexture(c);
  tex.colorSpace = THREE.SRGBColorSpace;
  return tex;
}

// MARK: - 着色器

const HASH = /* glsl */`
  float hash11(float n) { return fract(sin(n * 12.9898) * 43758.5453); }
`;

/// 显示器屏幕：工作中一行行代码方块往上滚、最后一行在打字、零星方块闪；待确认橙色闪「!」；出错红色；空闲暗着、光标在闪。
/// 每块屏一个实例，状态、随机种子、刚收到消息的时间都是实例属性
export function screenMaterial(brand) {
  return new THREE.ShaderMaterial({
    uniforms: { uTime: { value: 0 }, uBrand: { value: new THREE.Color(brand) } },
    vertexShader: /* glsl */`
      attribute float aState;
      attribute float aSeed;
      attribute float aFlash;
      varying vec2 vUv;
      varying float vState;
      varying float vSeed;
      varying float vFlash;
      void main() {
        vUv = uv; vState = aState; vSeed = aSeed; vFlash = aFlash;
        gl_Position = projectionMatrix * modelViewMatrix * instanceMatrix * vec4(position, 1.0);
      }`,
    fragmentShader: /* glsl */`
      uniform float uTime;
      uniform vec3 uBrand;
      varying vec2 vUv;
      varying float vState;
      varying float vSeed;
      varying float vFlash;
      ${HASH}
      // 一行行代码方块：rows 行，scroll 是滚过的行数，typing 是最后一行打到哪（0～1）
      vec3 code(vec2 uv, float seed, float scroll, float typing, float rows, float flicker) {
        float fromTop = (1.0 - uv.y) * rows;
        float r = floor(fromTop);
        float fy = fract(fromTop);
        if (fy < 0.22 || fy > 0.74) return vec3(0.0);
        float line = r + scroll;
        float rs = seed * 91.7 + line * 7.13;
        if (hash11(rs + 5.0) < 0.12) return vec3(0.0);             // 空行
        float indent = 0.05 + floor(hash11(rs) * 4.0) * 0.055;
        float len = 0.2 + hash11(rs + 1.3) * 0.62;
        if (r >= rows - 1.0) len *= typing;                           // 正在打的那一行
        if (uv.x < indent || uv.x > indent + len) return vec3(0.0);
        float tokens = 2.0 + floor(hash11(rs + 2.0) * 5.0);
        float tx = (uv.x - indent) / max(len, 0.001) * tokens;
        float ti = floor(tx);
        if (fract(tx) > 0.86) return vec3(0.0);
        float k = hash11(rs + ti * 3.1);
        vec3 c = k < 0.3 ? uBrand : (k < 0.62 ? vec3(0.42, 0.48, 0.56) : (k < 0.86 ? vec3(0.78) : vec3(0.36, 0.62, 0.52)));
        // 零星方块一闪一闪
        float blink = hash11(ti + line * 13.0 + floor(uTime * 7.0 + seed * 5.0));
        if (blink > 1.0 - flicker) c *= 2.1;
        return c;
      }
      float box(vec2 p, vec2 c, vec2 s) { vec2 d = abs(p - c) - s; return step(max(d.x, d.y), 0.0); }
      void main() {
        vec2 uv = vUv;
        float t = uTime;
        vec3 col = vec3(0.025, 0.03, 0.04);
        if (vState < 0.5) {
          // 空闲：暗着的代码 + 闪烁的光标
          col += code(uv, vSeed, 0.0, 1.0, 11.0, 0.0) * 0.22;
          col += box(uv, vec2(0.12, 0.08), vec2(0.018, 0.03)) * step(0.5, fract(t * 0.9 + vSeed)) * vec3(0.6);
        } else if (vState < 1.5) {
          // 工作中：往上滚、打字、闪
          float speed = 0.9 + vSeed * 0.8;
          float s = t * speed + vSeed * 40.0;
          col += code(uv, vSeed, floor(s), fract(s), 11.0, 0.08) * 0.85;
          col += vec3(0.02, 0.025, 0.03) * (0.5 + 0.5 * sin(uv.y * 400.0));   // 扫描线
        } else if (vState < 2.5) {
          // 待确认：橙色呼吸 + 「!」
          float pulse = 0.5 + 0.5 * sin(t * 4.0);
          col = mix(vec3(0.05), vec3(1.0, 0.62, 0.04) * 0.55, 0.35 + 0.45 * pulse);
          vec2 p = vec2((uv.x - 0.5) * 1.73, uv.y);
          col = mix(col, vec3(1.0), box(p, vec2(0.0, 0.6), vec2(0.045, 0.2)) + box(p, vec2(0.0, 0.25), vec2(0.045, 0.05)));
        } else if (vState < 3.5) {
          // 出错：暗红、偶尔闪一下
          float glitch = step(0.93, hash11(floor(t * 9.0) + vSeed * 10.0));
          col = vec3(0.32, 0.05, 0.05) + glitch * vec3(0.25, 0.04, 0.04);
          vec2 p = vec2((uv.x - 0.5) * 1.73, uv.y - 0.5);
          float cross = step(abs(abs(p.x) - abs(p.y)), 0.05) * step(abs(p.x), 0.22);
          col = mix(col, vec3(1.0, 0.85, 0.85), cross);
        } else {
          // 设备离线：雪花
          col = vec3(hash11(floor(uv.x * 90.0) + floor(uv.y * 60.0) * 91.0 + floor(t * 12.0)) * 0.08);
        }
        // 刚收到消息：亮一下
        float since = t - vFlash;
        col += uBrand * 0.9 * max(0.0, 1.0 - since / 0.7) * step(0.0, since);
        // 边缘暗角
        vec2 q = uv - 0.5;
        col *= 1.0 - dot(q, q) * 0.9;
        gl_FragColor = vec4(col, 1.0);
        #include <colorspace_fragment>
      }`,
  });
}

/// 信号灯：每个灯一个实例，颜色是 instanceColor，按自己的节奏乱闪；aRate 跟着这家 agent 有几个会话在工作调快调慢
export function ledMaterial() {
  return new THREE.ShaderMaterial({
    uniforms: { uTime: { value: 0 } },
    vertexShader: /* glsl */`
      attribute float aSeed;
      attribute float aRate;
      varying vec3 vColor;
      varying float vOn;
      uniform float uTime;
      ${HASH}
      void main() {
        vColor = vec3(1.0);
        #ifdef USE_INSTANCING_COLOR
        vColor = instanceColor;
        #endif
        float tick = floor(uTime * aRate + aSeed * 97.0);
        vOn = step(0.42, hash11(tick * 1.37 + aSeed * 311.0));
        gl_Position = projectionMatrix * modelViewMatrix * instanceMatrix * vec4(position, 1.0);
      }`,
    fragmentShader: /* glsl */`
      varying vec3 vColor;
      varying float vOn;
      void main() {
        gl_FragColor = vec4(vColor * mix(0.1, 1.5, vOn), 1.0);
        #include <colorspace_fragment>
      }`,
  });
}

/// 贴花（脸、上衣印花）：一张图集，每个实例取其中一格（aCell = u0, v0, 宽, 高）
export function decalMaterial(map) {
  return new THREE.ShaderMaterial({
    uniforms: { map: { value: map }, uShade: { value: 1.0 } },
    vertexShader: /* glsl */`
      attribute vec4 aCell;
      varying vec2 vUv;
      void main() {
        vUv = aCell.xy + uv * aCell.zw;
        gl_Position = projectionMatrix * modelViewMatrix * instanceMatrix * vec4(position, 1.0);
      }`,
    fragmentShader: /* glsl */`
      uniform sampler2D map;
      uniform float uShade;
      varying vec2 vUv;
      void main() {
        vec4 c = texture2D(map, vUv);
        if (c.a < 0.5) discard;
        gl_FragColor = vec4(c.rgb * uShade, 1.0);
        #include <colorspace_fragment>
      }`,
    side: THREE.FrontSide,
  });
}

/// 地面：深灰画布 + 浅白格线（细格 2、粗格 10），按屏幕像素算线宽，远处格子密了自动淡掉
export function groundMaterial(p) {
  const uniforms = THREE.UniformsUtils.merge([THREE.UniformsLib.fog, {
    uBase: { value: new THREE.Color(p.canvas) },
    uLine: { value: new THREE.Color(p.grid) },
    uMinor: { value: p.gridMinor },
    uMajor: { value: p.gridMajor },
  }]);
  return new THREE.ShaderMaterial({
    uniforms,
    fog: true,
    vertexShader: /* glsl */`
      varying vec3 vWorld;
      #include <fog_pars_vertex>
      void main() {
        vec4 world = modelMatrix * vec4(position, 1.0);
        vWorld = world.xyz;
        vec4 mvPosition = viewMatrix * world;
        gl_Position = projectionMatrix * mvPosition;
        #include <fog_vertex>
      }`,
    fragmentShader: /* glsl */`
      uniform vec3 uBase;
      uniform vec3 uLine;
      uniform float uMinor;
      uniform float uMajor;
      varying vec3 vWorld;
      #include <fog_pars_fragment>
      float grid(vec2 p) {
        vec2 w = fwidth(p);
        vec2 g = abs(fract(p - 0.5) - 0.5) / max(w, vec2(1e-4));
        float line = 1.0 - min(min(g.x, g.y), 1.0);
        // 格子比像素还密时淡掉（免得糊成一片）
        return line * (1.0 - smoothstep(0.15, 0.5, max(w.x, w.y)));
      }
      void main() {
        vec2 p = vWorld.xz;
        float minor = grid(p / 2.0);
        float major = grid(p / 10.0);
        vec3 col = mix(uBase, uLine, max(minor * uMinor, major * uMajor));
        gl_FragColor = vec4(col, 1.0);
        #include <colorspace_fragment>
        #include <fog_fragment>
      }`,
  });
}
