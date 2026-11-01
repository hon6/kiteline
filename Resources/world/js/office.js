// 办公区：一个项目一块地毯 + 后面一面玻璃墙（墙上挂项目名、钉着最近的图），会话一人一张工位、一个我的世界风格的方块人。
// 工位、人的头 / 身子 / 胳膊 / 腿各是一组实例（InstancedMesh），每帧只改动作用到的矩阵；皮肤是一张图集，每人一格。
//
// 人的动作：坐着时按会话状态（工作中打字、待确认扭头举手、出错抱头、空闲趴在桌上睡觉、头顶冒 Zzz）；
// agent 之间发消息时（见 social.js）起身、走到对方那边、面对面说话打手势，再走回来坐下。

import * as THREE from '../vendor/three.module.min.js';
import {
  mat, workstationGeometry, plantGeometry, mugGeometry, headGeometry, bodyGeometry, armGeometry, legGeometry,
  markerGeometry, screenMaterial, decalMaterial, skinMaterial, radialTexture, SCREEN, FIG,
} from './parts.js';
import { FACE, faceAtlas, AvatarAtlas, SkinAtlas, lookFor } from './atlas.js';

const STATE = { idle: 0, busy: 1, waiting: 2, error: 3, offline: 4 };
/// 项目区后面那面玻璃墙（待办墙）多高：10-27 改为原来 3.5 的 2.5 倍，便签从上往下贴得下一长列
export const WALL_H = 8.75;
/// 墙顶项目名牌子多高（signs.js 画、board.js 便签从它下面开始贴）：10-27 改为 1.25 的 1.5 倍
export const SIGN_H = 1.875;
const AISLE = 1.7;          // 起身后站在凳子后面多远
const WALK_SPEED = 5.5;
const STAND_HIP = 12 * 0.13;  // 站着时胯的高度 = 腿长
const tmpA = new THREE.Matrix4(), tmpB = new THREE.Matrix4(), tmpC = new THREE.Matrix4();
const v3 = new THREE.Vector3(), sc = new THREE.Vector3(), q = new THREE.Quaternion(), e = new THREE.Euler();
const zero = new THREE.Matrix4().makeScale(0, 0, 0);

export function hashOf(text) {
  let h = 2166136261;
  for (let i = 0; i < text.length; i++) { h ^= text.charCodeAt(i); h = Math.imul(h, 16777619); }
  return (h >>> 0) / 4294967295;
}

function compose(out, x, y, z, rx, ry, rz, s = 1) {
  return out.compose(v3.set(x, y, z), q.setFromEuler(e.set(rx, ry, rz)), sc.setScalar(s));
}

function instanced(geometry, material, count, colors) {
  const mesh = new THREE.InstancedMesh(geometry, material, Math.max(1, count));
  mesh.count = count;
  mesh.frustumCulled = false;
  if (colors) for (let i = 0; i < count; i++) mesh.setColorAt(i, colors(i));
  return mesh;
}

const zHead = new THREE.Vector3(), zRight = new THREE.Vector3(), zUp = new THREE.Vector3(), zPos = new THREE.Vector3(), zScale = new THREE.Vector3();
const zMat = new THREE.Matrix4(), zQuat = new THREE.Quaternion(), zSpin = new THREE.Quaternion(), zAxis = new THREE.Vector3(0, 0, 1);
/// 三个 Z：大小（世界单位，头是 1.04）、往右偏、往上抬
const Z_SIZES = [[0.42, 0.0, 0.0], [0.7, 0.55, 0.55], [1.04, 1.3, 1.35]];

/// 像素「Z」：白字深色描边，放大时保持方块
function zTexture() {
  const c = document.createElement('canvas');
  c.width = c.height = 16;
  const g = c.getContext('2d');
  const shape = ['########', '      ##', '     ## ', '    ##  ', '   ##   ', '  ##    ', ' ##     ', '########'];
  const at = (x, y, color) => { g.fillStyle = color; g.fillRect(x, y, 1, 1); };
  shape.forEach((row, y) => [...row].forEach((ch, x) => {
    if (ch !== '#') return;
    for (const [dx, dy] of [[-1, 0], [1, 0], [0, -1], [0, 1], [1, 1]]) at(x + 4 + dx, y + 4 + dy, '#24304A');
  }));
  shape.forEach((row, y) => [...row].forEach((ch, x) => { if (ch === '#') at(x + 4, y + 4, '#EEF3FF'); }));
  const tex = new THREE.CanvasTexture(c);
  tex.colorSpace = THREE.SRGBColorSpace;
  tex.magFilter = THREE.NearestFilter;
  tex.minFilter = THREE.NearestFilter;
  tex.generateMipmaps = false;
  return tex;
}

const smooth = (u) => u * u * (3 - 2 * u);
const wrap = (a) => Math.atan2(Math.sin(a), Math.cos(a));
/// 人朝 -z 时 yaw = 0；面朝 (dx, dz) 方向的 yaw
export const yawToward = (dx, dz) => Math.atan2(-dx, -dz);

export class Office {
  constructor(world) {
    this.world = world;
    this.group = new THREE.Group();
    world.scene.add(this.group);
    this.figures = [];
    this.byKey = new Map();
    this.faces = faceAtlas();
    this.skins = new SkinAtlas();
    this.skinMat = skinMaterial(this.skins.texture);
    this.skinMat.shared = true;
    this.shadowTex = radialTexture('rgba(0,0,0,1)', 'rgba(0,0,0,0)');
  }

  dispose() {
    for (const child of [...this.group.children]) {
      this.group.remove(child);
      child.geometry?.dispose();
      if (child.material && !child.material.shared) child.material.dispose?.();
    }
  }

  /// 按排好的位置重建（会话增减时）；之前就在的人不重新从天上掉，站着、走着的接着站、接着走
  build(layout, data, palette) {
    const previous = new Map([...this.byKey].map(([k, i]) => [k, this.figures[i]]));
    this.dispose();
    this.palette = palette;
    this.avatars ??= new AvatarAtlas(this.world.mediaBase, this.world.marks, true);
    this.avatars.suffix = this.world.mediaSuffix || '';   // 直连模式：头像图要带令牌
    this.avatars.onChange = () => this.world.invalidate();
    const now = this.world.time;
    this.figures = [];
    this.byKey = new Map();
    for (const zone of layout.zones) {
      for (const desk of zone.desks) {
        const h = hashOf(desk.key);
        const old = previous.get(desk.key);
        const keep = old && old.x === desk.x && old.z === desk.z;
        const fig = {
          key: desk.key, x: desk.x, z: desk.z, seed: h, project: zone.name,
          // 新来的从天上掉下来（第一次打开世界时不掉，免得满屏下雨）
          spawnAt: old ? old.spawnAt : (this.world.ready ? now : -10),
          pose: old ? old.pose : { lean: 0, headRx: 0, headRy: 0, aLx: 1.2, aLz: 0, aRx: 1.2, aRz: 0 },
          // 走动：phase = seated / rising / standing / walking / sitting；位置、朝向、站起来多少（0 坐 1 站）。
          // 换了座位（重排）的直接坐到新座位上
          m: keep ? old.m : { phase: 'seated', x: desk.x, z: desk.z, yaw: 0, stand: 0, t: 0, path: [], swing: 0, faceYaw: null, gesture: null },
          want: keep ? old.want : null,
          state: old ? old.state : STATE.idle, idleSince: old ? old.idleSince : null, face: FACE.smile, marker: 0,
        };
        this.byKey.set(fig.key, this.figures.length);
        this.figures.push(fig);
      }
    }
    const n = this.figures.length;
    const p = palette;
    const lambert = (opts) => new THREE.MeshLambertMaterial(opts);

    // 项目区：地毯、玻璃墙、上下框
    const zones = layout.zones;
    this.carpets = instanced(new THREE.BoxGeometry(1, 1, 1), lambert({}), zones.length,
      (i) => new THREE.Color(p.carpets[Math.floor(hashOf(zones[i].name) * 7919) % p.carpets.length]));
    this.glass = instanced(new THREE.BoxGeometry(1, 1, 1),
      new THREE.MeshLambertMaterial({ color: p.glass, transparent: true, opacity: p.glassOpacity, depthWrite: false }), zones.length);
    this.rails = instanced(new THREE.BoxGeometry(1, 1, 1), lambert({ color: p.rail }), zones.length * 3);
    zones.forEach((zone, i) => {
      const cx = zone.x + zone.w / 2, cz = zone.z + zone.d / 2;
      this.carpets.setMatrixAt(i, mat(cx, 0.06, cz, 0, 0, 0, zone.w, 0.12, zone.d));
      // 玻璃从 0.1 到 0.1 + WALL_H，上框压在顶上，两边立框从地面到上框
      this.glass.setMatrixAt(i, mat(cx, 0.1 + WALL_H / 2, zone.z + 0.25, 0, 0, 0, zone.w, WALL_H, 0.1));
      this.rails.setMatrixAt(i * 3, mat(cx, WALL_H + 0.15, zone.z + 0.25, 0, 0, 0, zone.w + 0.1, 0.14, 0.22));
      this.rails.setMatrixAt(i * 3 + 1, mat(zone.x + 0.05, (WALL_H + 0.2) / 2, zone.z + 0.25, 0, 0, 0, 0.14, WALL_H + 0.1, 0.22));
      this.rails.setMatrixAt(i * 3 + 2, mat(zone.x + zone.w - 0.05, (WALL_H + 0.2) / 2, zone.z + 0.25, 0, 0, 0, 0.14, WALL_H + 0.1, 0.22));
    });
    this.glass.renderOrder = 2;

    // 工位、屏幕、上下文用量条、摆设、软阴影
    this.stations = instanced(workstationGeometry(p), lambert({ vertexColors: true }), n);
    const screenGeo = new THREE.PlaneGeometry(SCREEN.w, SCREEN.h);
    this.screenState = new THREE.InstancedBufferAttribute(new Float32Array(Math.max(1, n)), 1);
    this.screenFlash = new THREE.InstancedBufferAttribute(new Float32Array(Math.max(1, n)).fill(-10), 1);
    screenGeo.setAttribute('aState', this.screenState);
    screenGeo.setAttribute('aSeed', new THREE.InstancedBufferAttribute(Float32Array.from({ length: Math.max(1, n) }, (_, i) => this.figures[i]?.seed ?? 0), 1));
    screenGeo.setAttribute('aFlash', this.screenFlash);
    this.screenMat = screenMaterial(this.world.brand);
    this.screens = instanced(screenGeo, this.screenMat, n);
    this.meters = instanced(new THREE.BoxGeometry(1, 1, 1), new THREE.MeshBasicMaterial({ color: 0xffffff }), n, () => new THREE.Color(0x6A8A70));
    const plants = this.figures.filter(f => Math.floor(f.seed * 211) % 3 === 0);
    const mugs = this.figures.filter(f => Math.floor(f.seed * 127) % 2 === 0);
    this.plants = instanced(plantGeometry(p), lambert({ vertexColors: true }), plants.length);
    this.mugs = instanced(mugGeometry(p), lambert({ vertexColors: true }), mugs.length);
    plants.forEach((f, i) => this.plants.setMatrixAt(i, mat(f.x - 2.15, 2.54, f.z - 2.95)));
    mugs.forEach((f, i) => this.mugs.setMatrixAt(i, mat(f.x + 1.95, 2.54, f.z - 1.4)));
    this.shadows = instanced(new THREE.PlaneGeometry(1, 1).rotateX(-Math.PI / 2),
      new THREE.MeshBasicMaterial({ map: this.shadowTex, color: 0x000000, transparent: true, opacity: p.shadow, depthWrite: false }), n);
    this.shadows.renderOrder = 1;
    this.figures.forEach((f, i) => {
      this.stations.setMatrixAt(i, mat(f.x, 0, f.z));
      this.screens.setMatrixAt(i, mat(f.x, SCREEN.y, f.z + SCREEN.z + 0.03));
      this.shadows.setMatrixAt(i, mat(f.x, 0.13, f.z - 1.3, 0, 0, 0, 7.5, 1, 5.5));
    });

    // 方块人：头、身子、胳膊（两条）、腿（两条），每个实例带自己那格皮肤
    const withCells = (geometry, per) => {
      const attr = new THREE.InstancedBufferAttribute(new Float32Array(Math.max(1, n * per) * 4), 4);
      geometry.setAttribute('aCell', attr);
      return { geometry, attr, per };
    };
    this.skinParts = {
      heads: withCells(headGeometry(), 1), bodies: withCells(bodyGeometry(), 1),
      arms: withCells(armGeometry(), 2), legs: withCells(legGeometry(), 2),
    };
    for (const [name, part] of Object.entries(this.skinParts)) this[name] = instanced(part.geometry, this.skinMat, n * part.per);
    this.markers = instanced(markerGeometry(), new THREE.MeshBasicMaterial({ color: 0xffffff }), n, () => new THREE.Color(0xFF9F0A));
    // 脸（像素表情）、后背的头像牌
    const faceGeo = new THREE.PlaneGeometry(1, 1);
    this.faceCells = new THREE.InstancedBufferAttribute(new Float32Array(Math.max(1, n) * 4), 4);
    faceGeo.setAttribute('aCell', this.faceCells);
    this.faceDecals = instanced(faceGeo, decalMaterial(this.faces.texture), n);
    const printGeo = new THREE.PlaneGeometry(1, 1);
    this.printCells = new THREE.InstancedBufferAttribute(new Float32Array(Math.max(1, n) * 4), 4);
    printGeo.setAttribute('aCell', this.printCells);
    this.prints = instanced(printGeo, decalMaterial(this.avatars.texture), n);
    for (const f of this.figures) f.faceShown = null;
    // 打呼的 Z：每个人三个（一个比一个大），像素贴图、始终面向镜头
    this.zzz = instanced(new THREE.PlaneGeometry(1, 1), new THREE.MeshBasicMaterial({ map: zTexture(), transparent: true, alphaTest: 0.5, depthWrite: false }), n * 3);
    this.zzz.renderOrder = 4;

    // 选中、悬停的方框（像素风：方的）
    const square = (inner, outer) => {
      const shape = new THREE.Shape([new THREE.Vector2(-outer, -outer), new THREE.Vector2(outer, -outer), new THREE.Vector2(outer, outer), new THREE.Vector2(-outer, outer)]);
      shape.holes.push(new THREE.Path([new THREE.Vector2(-inner, -inner), new THREE.Vector2(-inner, inner), new THREE.Vector2(inner, inner), new THREE.Vector2(inner, -inner)]));
      return new THREE.ShapeGeometry(shape).rotateX(-Math.PI / 2);
    };
    this.ring = new THREE.Mesh(square(2.5, 2.85), new THREE.MeshBasicMaterial({ color: this.world.brand, transparent: true, opacity: 0, depthWrite: false }));
    this.hoverRing = new THREE.Mesh(square(2.6, 2.75), new THREE.MeshBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0, depthWrite: false }));

    for (const mesh of [this.carpets, this.shadows, this.stations, this.screens, this.meters, this.plants, this.mugs,
      this.heads, this.bodies, this.arms, this.legs, this.markers, this.faceDecals, this.prints, this.zzz, this.glass, this.rails, this.ring, this.hoverRing]) {
      this.group.add(mesh);
    }
    for (const mesh of [this.carpets, this.glass, this.rails, this.stations, this.plants, this.mugs, this.shadows]) {
      mesh.instanceMatrix.needsUpdate = true;
    }
    this.update(data);
  }

  /// 状态变了（工作中 / 待确认 / 出错 / 设备离线、头像、用量）：只改实例属性，不重建
  update(data) {
    const { heads, bodies, arms, legs } = this.skinParts;
    this.figures.forEach((f, i) => {
      const s = data.sessions.get(f.key);
      if (!s) return;
      const source = data.sources.get(s.sourceId);
      const offline = source && !source.online;
      const was = f.state;
      f.state = offline ? STATE.offline : s.failed ? STATE.error : s.activity === 'waiting' ? STATE.waiting : s.activity === 'busy' ? STATE.busy : STATE.idle;
      // 刚闲下来先靠着歇几秒再趴下睡；打开世界时就闲着的直接在睡
      if (f.state === STATE.idle && (was !== STATE.idle || f.idleSince == null)) f.idleSince = f.idleSince == null && !this.world.ready ? -100 : this.world.time;
      f.face = f.state === STATE.busy ? FACE.focused : f.state === STATE.waiting ? FACE.asking : f.state === STATE.error ? FACE.sad : FACE.smile;
      this.screenState.setX(i, f.state);
      // 皮肤（按会话定长相）、后背头像牌
      const skin = this.skins.cellFor(f.key, lookFor(s, f.seed));
      heads.attr.setXYZW(i, ...skin); bodies.attr.setXYZW(i, ...skin);
      for (const k of [0, 1]) { arms.attr.setXYZW(i * 2 + k, ...skin); legs.attr.setXYZW(i * 2 + k, ...skin); }
      this.printCells.setXYZW(i, ...this.avatars.cellFor(s));
      // 上下文用量：显示器右边一根小条，越满越红
      const ratio = s.context == null ? 0 : Math.min(1, s.context / 100);
      this.meters.setMatrixAt(i, ratio > 0 ? mat(f.x + SCREEN.w / 2 + 0.26, SCREEN.y - SCREEN.h / 2 + ratio * SCREEN.h / 2 - 0.05, f.z + SCREEN.z - 0.02, 0, 0, 0, 0.12, Math.max(0.04, ratio * SCREEN.h), 0.12) : zero);
      this.meters.setColorAt(i, new THREE.Color(ratio > 0.85 ? 0xD9534F : ratio > 0.6 ? 0xD99A3A : 0x6A8A70));
      f.marker = f.state === STATE.waiting ? 1 : f.state === STATE.error ? 2 : 0;
      this.markers.setColorAt(i, new THREE.Color(f.marker === 2 ? 0xE5484D : 0xFF9F0A));
    });
    for (const part of Object.values(this.skinParts)) part.attr.needsUpdate = true;
    this.screenState.needsUpdate = true;
    this.printCells.needsUpdate = true;
    this.meters.instanceMatrix.needsUpdate = true;
    if (this.meters.instanceColor) this.meters.instanceColor.needsUpdate = true;
    if (this.markers.instanceColor) this.markers.instanceColor.needsUpdate = true;
  }

  flash(key) {
    const i = this.byKey.get(key);
    if (i == null) return;
    this.figures[i].cheerUntil = this.world.time + 1.6;
    this.screenFlash.setX(i, this.world.time);
    this.screenFlash.needsUpdate = true;
  }

  // MARK: 走动（social.js 叫）

  fig(key) { const i = this.byKey.get(key); return i == null ? null : this.figures[i]; }

  /// 起身，站到 spot（不给就站在自己凳子后面）
  wantStand(key, spot) {
    const f = this.fig(key);
    if (!f) return;
    const target = spot || { x: f.x, z: f.z + AISLE };
    if (!f.want || f.want.type !== 'stand' || Math.hypot(f.want.x - target.x, f.want.z - target.z) > 0.2) f.want = { type: 'stand', x: target.x, z: target.z };
  }

  /// 回自己座位坐下
  wantSit(key) {
    const f = this.fig(key);
    if (f && f.want?.type !== 'sit' && f.m.phase !== 'seated') { f.want = { type: 'sit' }; f.m.gesture = null; f.m.faceYaw = null; }
  }

  face(key, yaw) { const f = this.fig(key); if (f) f.m.faceYaw = yaw; }
  gesture(key, kind) { const f = this.fig(key); if (f) f.m.gesture = kind; }

  /// 到了要站的地方、站稳了
  arrived(key) {
    const f = this.fig(key);
    return !!f && f.m.phase === 'standing' && (!f.want || f.want.type !== 'stand' || Math.hypot(f.m.x - f.want.x, f.m.z - f.want.z) < 0.4);
  }

  aislePos(key) { const f = this.fig(key); return f ? { x: f.x, z: f.z + AISLE } : null; }
  standPos(key) { const f = this.fig(key); return f ? { x: f.m.x, z: f.m.z } : null; }

  move(f, dt) {
    const m = f.m;
    const seat = { x: f.x, z: f.z }, aisle = { x: f.x, z: f.z + AISLE };
    const want = f.want;
    const go = (target) => {
      m.path = this.world.nav ? this.world.nav.path({ x: m.x, z: m.z }, target) : [target];
      m.goal = target;
      m.phase = 'walking';
    };
    switch (m.phase) {
      case 'seated':
        m.x = seat.x; m.z = seat.z; m.stand = 0;
        if (want?.type === 'stand') { m.phase = 'rising'; m.t = 0; }
        break;
      case 'rising':
      case 'sitting': {
        m.t = Math.min(1, m.t + dt / 0.7);
        const k = m.phase === 'rising' ? smooth(m.t) : 1 - smooth(m.t);
        m.x = seat.x + (aisle.x - seat.x) * k;
        m.z = seat.z + (aisle.z - seat.z) * k;
        m.stand = k;
        m.yaw = wrap(m.yaw * (1 - Math.min(1, dt * 6)));
        if (m.t >= 1) {
          m.phase = m.phase === 'rising' ? 'standing' : 'seated';
          if (m.phase === 'seated') { f.want = null; m.yaw = 0; }
        }
        break;
      }
      case 'standing':
        m.stand = 1;
        if (!want || want.type === 'sit') {
          if (Math.hypot(m.x - aisle.x, m.z - aisle.z) > 0.3) go(aisle);
          else if (Math.abs(wrap(m.yaw)) > 0.2) m.yaw += wrap(-m.yaw) * Math.min(1, dt * 8);   // 先转回来对着桌子
          else { m.phase = 'sitting'; m.t = 0; }
        } else if (Math.hypot(m.x - want.x, m.z - want.z) > 0.4) {
          go({ x: want.x, z: want.z });
        } else if (m.faceYaw != null) {
          m.yaw += wrap(m.faceYaw - m.yaw) * Math.min(1, dt * 7);
        }
        break;
      case 'walking': {
        // 中途改主意（要站的地方变了 / 让回去坐下）：从这里重新找路
        const goal = want?.type === 'stand' ? want : aisle;
        if (!m.goal || Math.hypot(m.goal.x - goal.x, m.goal.z - goal.z) > 0.4) go({ x: goal.x, z: goal.z });
        const next = m.path[0];
        if (!next) { m.phase = 'standing'; break; }
        const dx = next.x - m.x, dz = next.z - m.z, dist = Math.hypot(dx, dz);
        const step = WALK_SPEED * dt;
        if (dist > 0.01) m.yaw += wrap(yawToward(dx, dz) - m.yaw) * Math.min(1, dt * 10);
        if (dist <= step) { m.x = next.x; m.z = next.z; m.path.shift(); }
        else { m.x += dx / dist * step; m.z += dz / dist * step; }
        m.swing += dt * 9;
        if (!m.path.length) m.phase = 'standing';
        break;
      }
    }
  }

  /// 每帧：走动 + 各人的动作（往目标姿势平滑过渡，再叠打字、挥手、比划这些小动作）
  tick(time, dt) {
    if (!this.figures.length) return;
    this.screenMat.uniforms.uTime.value = time;
    const k = 1 - Math.exp(-dt * 5);
    const body = tmpA, part = tmpB, child = tmpC;
    let facesChanged = false;
    this.figures.forEach((f, i) => {
      this.move(f, dt);
      const m = f.m, P = f.pose;
      const st = f.state, sd = f.seed * 10;
      const standing = m.stand > 0.5;
      const walking = m.phase === 'walking';
      const talking = standing && !walking && m.gesture === 'talk';
      f.asleep = st === STATE.idle && !standing && m.phase === 'seated' && time - f.idleSince > 5 && !(f.cheerUntil > time);
      // 目标姿势：站着看手势，坐着看会话状态（lean 负 = 往前趴，正 = 往后靠）
      let lean = -0.04, headRx = -0.05, headRy = 0, aLx = 1.2, aLz = 0.06, aRx = 1.2, aRz = -0.06;
      if (standing) {
        lean = 0; headRx = 0;
        if (talking) { aLx = 0.95; aLz = -0.2; aRx = 0.95; aRz = 0.2; }
        else if (m.gesture === 'reach') { aLx = 0.3; aRx = 2.2; aRz = 0.1; }   // 伸手贴 / 撕墙上的便签
        else if (f.carrying) { aLx = 0.08; aRx = 1.15; aRz = 0.15; }          // 手里拿着便签
        else { aLx = 0.06; aLz = -0.04; aRx = 0.06; aRz = 0.04; }
      } else if (f.asleep) {
        // 趴在桌上睡：身子往前趴，两只胳膊叠在桌上，脸侧着枕在胳膊上，一起一伏地喘气
        lean = -0.86 + Math.sin(time * 1.3 + sd) * 0.025; headRx = 0.12; headRy = 0.85; aLx = 2.28; aLz = 0.5; aRx = 2.28; aRz = -0.5;
      } else if (st === STATE.idle) {
        lean = 0.1; headRy = 0.35 * Math.sin(time * 0.35 + sd); aLx = 0.45; aRx = 0.45;   // 刚闲下来：往后靠着、左右看看
      } else if (st === STATE.waiting) {
        headRy = Math.PI; aRx = Math.PI - 0.25; aRz = -0.12; aLx = 1.1;   // 扭过头来看你、举手
      } else if (st === STATE.error) {
        headRy = Math.PI; aLx = Math.PI - 0.5; aLz = -0.45; aRx = Math.PI - 0.5; aRz = 0.45;   // 抱头
      } else if (st === STATE.offline) {
        lean = -0.18; headRx = 0.25; aLx = 0.25; aRx = 0.25;
      }
      const cheer = !standing && f.cheerUntil > time && st !== STATE.waiting && st !== STATE.error;
      if (cheer) { aRx = Math.PI - 0.4; aRz = -0.2; }
      P.lean += (lean - P.lean) * k; P.headRx += (headRx - P.headRx) * k; P.headRy += wrap(headRy - P.headRy) * k;
      P.aLx += (aLx - P.aLx) * k; P.aLz += (aLz - P.aLz) * k; P.aRx += (aRx - P.aRx) * k; P.aRz += (aRz - P.aRz) * k;

      // 叠上去的小动作
      let tapL = 0, tapR = 0, nod = 0, wave = 0, shake = 0;
      const swing = walking ? Math.sin(m.swing) : 0;
      if (walking) { tapL = swing * 0.75; tapR = f.carrying ? 0 : -swing * 0.75; }
      else if (talking) {
        // 说话：两只手轮流比划、点头
        tapL = Math.sin(time * 6.2 + sd) * 0.55; tapR = Math.sin(time * 5.3 + sd + 2.1) * 0.55;
        wave = Math.sin(time * 3.6 + sd) * 0.22; nod = Math.sin(time * 5 + sd) * 0.07;
      } else if (standing && m.gesture === 'listen') {
        nod = Math.max(0, Math.sin(time * 1.8 + sd)) * 0.12;
      } else if (st === STATE.busy && !standing) {
        const speed = 15 + f.seed * 6;
        tapL = Math.sin(time * speed + sd) * 0.08; tapR = Math.sin(time * speed + sd + 2.1) * 0.08;
        nod = Math.sin(time * 2.2 + sd) * 0.04;
      } else if (st === STATE.waiting && !standing) {
        wave = Math.sin(time * 7 + sd) * 0.3;
      } else if (st === STATE.error && !standing) {
        shake = Math.sin(time * 8 + sd) * 0.12;
      }
      if (cheer) wave = Math.sin(time * 14) * 0.3;
      // 表情：说话时嘴一张一合，站着笑，坐着看会话状态
      const faceNow = talking ? (Math.sin(time * 13 + sd) > 0 ? FACE.talk : FACE.smile) : standing ? FACE.smile : f.asleep ? FACE.sleepy : f.face;
      if (faceNow !== f.faceShown) { f.faceShown = faceNow; this.faceCells.setXYZW(i, ...this.faces.cell(faceNow)); facesChanged = true; }

      // 从天上掉下来：0.9 秒，落地弹一下；要走的升上去
      const age = time - f.spawnAt;
      let drop = 0, scale = 1;
      if (age < 0.9) {
        const u = Math.max(0, age / 0.9);
        drop = (1 - u) * (1 - u) * 14;
        if (u > 0.82) drop = Math.sin((u - 0.82) / 0.18 * Math.PI) * 0.35;
        scale = 0.6 + 0.4 * Math.min(1, u * 1.5);
      }
      const leave = f.leavingAt != null ? Math.min(1, (time - f.leavingAt) / 1.1) : 0;
      if (leave > 0) { drop = leave * leave * 18; scale = 1 - leave; }

      const hip = (FIG.hip + (STAND_HIP - FIG.hip) * m.stand) * scale + drop;
      const legRx = (Math.PI / 2) * (1 - m.stand);
      // 腿（走路时前后摆）
      compose(body, m.x, hip, m.z, 0, m.yaw, 0, scale);
      [[-FIG.leg.x, -swing * 0.7], [FIG.leg.x, swing * 0.7]].forEach(([x, s], side) => {
        compose(child, x, 0, 0, legRx + s, 0, 0);
        this.legs.setMatrixAt(i * 2 + side, part.multiplyMatrices(body, child));
      });
      // 身子（原点在胯），坐着时往后靠一点
      body.multiply(compose(child, 0, 0, 0, P.lean * (1 - m.stand), 0, 0));
      this.bodies.setMatrixAt(i, body);
      // 后背头像牌
      compose(child, 0, 0.86, FIG.body.d / 2 + 0.012, 0, 0, 0); child.scale(v3.set(0.6, 0.6, 1));
      this.prints.setMatrixAt(i, child.premultiply(body));
      // 头、脸（坐着等你确认、出错时扭过头来看你；站起来就看着说话的人）
      const turn = standing ? 0 : P.headRy;
      compose(child, 0, FIG.body.h, 0, P.headRx + nod, turn + shake, 0);
      part.multiplyMatrices(body, child);
      this.heads.setMatrixAt(i, part);
      if (f.asleep) {
        // 打呼：头顶上方约 20 厘米（方块人 1.8 米高 ≈ 4.2 个单位），三个 Z 由小到大往右上排，最大的和头差不多大，慢慢抖
        const head = zHead.set(0, FIG.head / 2, 0).applyMatrix4(part);
        const right = zRight.setFromMatrixColumn(this.world.camera.matrixWorld, 0).setY(0).normalize();
        const breath = 1 + Math.sin(time * 1.3 + sd) * 0.06;
        Z_SIZES.forEach(([size, dx, dy], k) => {
          const wobble = Math.sin(time * 2.2 + sd + k * 1.7) * 0.16;
          zPos.copy(head).addScaledVector(right, dx).add(zUp.set(0, FIG.head / 2 + 0.46 + dy + Math.sin(time * 1.6 + k + sd) * 0.05, 0));
          zQuat.copy(this.world.camera.quaternion).multiply(zSpin.setFromAxisAngle(zAxis, wobble));
          this.zzz.setMatrixAt(i * 3 + k, zMat.compose(zPos, zQuat, zScale.setScalar(size * breath)));
        });
      } else {
        for (let k = 0; k < 3; k++) this.zzz.setMatrixAt(i * 3 + k, zero);
      }
      compose(child, 0, FIG.head / 2, -FIG.head / 2 - 0.012, 0, Math.PI, 0); child.scale(v3.set(FIG.head, FIG.head, 1));
      this.faceDecals.setMatrixAt(i, child.premultiply(part));
      // 胳膊
      const waveR = talking || (!standing && (st === STATE.waiting || cheer)) ? wave : 0;
      const arms = [[-FIG.shoulder.x, P.aLx + tapL, P.aLz - (talking ? wave : 0)], [FIG.shoulder.x, P.aRx + tapR, P.aRz + waveR]];
      arms.forEach(([x, rx, rz], side) => {
        compose(child, x, FIG.shoulder.y, 0, rx, 0, rz);
        this.arms.setMatrixAt(i * 2 + side, part.multiplyMatrices(body, child));
      });
      // 显示器旁边的标记：待确认橙、出错红，上下浮、慢慢转（不挡屏幕和名牌）
      if (f.marker && leave === 0) {
        this.markers.setMatrixAt(i, compose(part, f.x + SCREEN.w / 2 + 0.9, 4.7 + Math.sin(time * 2.4 + sd) * 0.18, f.z + SCREEN.z + 0.4, 0, time * 1.6 + sd, 0));
      } else this.markers.setMatrixAt(i, zero);
    });
    for (const mesh of [this.heads, this.bodies, this.arms, this.legs, this.faceDecals, this.prints, this.markers, this.zzz]) mesh.instanceMatrix.needsUpdate = true;
    if (facesChanged) this.faceCells.needsUpdate = true;
    // 选中、悬停的方框：跟着人走
    const ring = (mesh, key, opacity) => {
      const f = key != null ? this.fig(key) : null;
      mesh.material.opacity = f ? opacity : 0;
      if (f) mesh.position.set(f.m.x, 0.16, f.m.z - 1.2 * (1 - f.m.stand));
    };
    ring(this.ring, this.world.selected, 0.6 + 0.25 * Math.sin(time * 3));
    ring(this.hoverRing, this.world.hovered !== this.world.selected ? this.world.hovered : null, 0.35);
  }

  /// 要走的人：往上升着变小（之后重建时就没了）
  leave(key) {
    const f = this.fig(key);
    if (f) f.leavingAt = this.world.time;
  }

  has(key) { return this.byKey.has(key); }

  screenPos(key, out = new THREE.Vector3()) {
    const f = this.fig(key);
    return f ? out.set(f.x, SCREEN.y, f.z + SCREEN.z + 0.1) : null;
  }

  /// 右手前面（拿便签的位置）
  handPos(key, out = new THREE.Vector3()) {
    const f = this.fig(key);
    if (!f) return null;
    const hip = FIG.hip + (STAND_HIP - FIG.hip) * f.m.stand;
    const fx = -Math.sin(f.m.yaw), fz = -Math.cos(f.m.yaw);
    return out.set(f.m.x + fx * 0.75 - fz * 0.35, hip + 1.05, f.m.z + fz * 0.75 + fx * 0.35);
  }

  /// 头顶（站着、走着时跟着人）
  headPos(key, out = new THREE.Vector3()) {
    const f = this.fig(key);
    if (!f) return null;
    const hip = FIG.hip + (STAND_HIP - FIG.hip) * f.m.stand;
    return out.set(f.m.x, hip + FIG.body.h + FIG.head + 0.1, f.m.z);
  }

  /// 名牌、气泡挂的地方：坐着时在显示器顶上（不挡屏幕：屏幕是点开会话的入口），站起来了跟着头顶走
  tagPos(key, out = new THREE.Vector3()) {
    const f = this.fig(key);
    if (!f) return null;
    if (f.m.stand > 0.5) return this.headPos(key, out).add(v3.set(0, 0.25, 0));
    return out.set(f.x, SCREEN.y + SCREEN.h / 2 + 0.16, f.z + SCREEN.z);
  }

  deskCenter(key, out = new THREE.Vector3()) {
    const f = this.fig(key);
    return f ? out.set(f.x, 2.5, f.z - 1.2) : null;
  }

  /// 点到的是哪个会话的屏幕 / 人
  pick(raycaster) {
    const targets = [this.screens, this.heads, this.bodies, this.arms, this.legs, this.prints, this.faceDecals, this.stations];
    const hits = raycaster.intersectObjects(targets.filter(Boolean), false);
    for (const hit of hits) {
      if (hit.instanceId == null) continue;
      const mesh = hit.object;
      const index = mesh === this.arms || mesh === this.legs ? hit.instanceId >> 1 : hit.instanceId;
      const fig = this.figures[index];
      if (!fig) continue;
      if (mesh === this.screens) return { type: 'screen', key: fig.key, point: hit.point };
      if (mesh === this.stations) {
        // 点在显示器外框上也算屏幕
        const onMonitor = hit.point.y > SCREEN.y - SCREEN.h / 2 - 0.15 && hit.point.z < fig.z + SCREEN.z + 0.3;
        return { type: onMonitor ? 'screen' : 'figure', key: fig.key, point: hit.point };
      }
      return { type: 'figure', key: fig.key, point: hit.point };
    }
    return null;
  }

  /// 项目区（点地毯、墙）
  pickZone(raycaster, layout) {
    if (!this.carpets) return null;
    const hits = raycaster.intersectObjects([this.carpets, this.glass], false);
    const hit = hits.find(h => h.instanceId != null);
    return hit ? layout.zones[hit.instanceId] : null;
  }
}
