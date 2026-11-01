// 机房：一家 agent 一间（Claude Code、Codex……），一排服务器机柜，信号灯各按各的节奏乱闪（这家有几个会话在工作就闪多快），
// 门口一面标志牌，旁边一口卫星天线，一直转着对准刚收发过消息的那颗卫星；光弧从天线发出去。

import * as THREE from '../vendor/three.module.min.js';
import { mat, rackGeometry, rackLedSlots, dishGeometry, ledMaterial, radialTexture, RACK, DISH_FEED } from './parts.js';
import { t } from './i18n.js';

const LED_COLORS = [0x3CE070, 0x3CE070, 0x3CE070, 0xFFB020, 0x4DA3FF];
const tmp = new THREE.Matrix4(), v = new THREE.Vector3();

export class DataCenter {
  constructor(world) {
    this.world = world;
    this.group = new THREE.Group();
    world.scene.add(this.group);
    this.rooms = [];
    this.shadowTex = radialTexture('rgba(0,0,0,1)', 'rgba(0,0,0,0)');
  }

  dispose() {
    for (const child of [...this.group.children]) {
      this.group.remove(child);
      child.geometry?.dispose();
      child.material?.map?.dispose();
      child.material?.dispose?.();
    }
  }

  build(layout, data, palette) {
    this.dispose();
    this.rooms = layout.rooms.map(r => ({ ...r, yaw: 0, target: null, rackIndex: [] }));
    const p = palette;
    const racks = [];
    this.rooms.forEach((room, ri) => {
      const span = room.racks * 3;
      for (let k = 0; k < room.racks; k++) {
        room.rackIndex.push(racks.length);
        racks.push({ room: ri, x: room.x + 2 + k * 3 + 1.5, z: room.z + 2.2 });
      }
      room.span = span;
    });

    // 架空地板
    const floor = new THREE.InstancedMesh(new THREE.BoxGeometry(1, 1, 1), new THREE.MeshLambertMaterial({ color: p.platform }), Math.max(1, this.rooms.length));
    floor.count = this.rooms.length;
    this.rooms.forEach((r, i) => floor.setMatrixAt(i, mat(r.x + r.w / 2, 0.2, r.z + r.d / 2, 0, 0, 0, r.w, 0.4, r.d)));
    this.group.add(floor);

    // 机柜
    this.racks = new THREE.InstancedMesh(rackGeometry(p), new THREE.MeshLambertMaterial({ vertexColors: true }), Math.max(1, racks.length));
    this.racks.count = racks.length;
    racks.forEach((r, i) => this.racks.setMatrixAt(i, mat(r.x, 0.4, r.z)));
    this.rackList = racks;
    this.group.add(this.racks);

    // 软阴影
    const shadows = new THREE.InstancedMesh(new THREE.PlaneGeometry(1, 1).rotateX(-Math.PI / 2),
      new THREE.MeshBasicMaterial({ map: this.shadowTex, color: 0x000000, transparent: true, opacity: p.shadow, depthWrite: false }), Math.max(1, this.rooms.length));
    shadows.count = this.rooms.length;
    this.rooms.forEach((r, i) => shadows.setMatrixAt(i, mat(r.x + r.w / 2, 0.03, r.z + r.d / 2, 0, 0, 0, r.w + 6, 1, r.d + 6)));
    shadows.renderOrder = 1;
    this.group.add(shadows);

    // 信号灯：每个机柜 12 层 × (6 + 1) 个 + 顶上一个航标灯
    const slots = rackLedSlots();
    const count = racks.length * slots.length;
    const geo = new THREE.BoxGeometry(0.11, 0.07, 0.05);
    const seeds = new Float32Array(count), rates = new Float32Array(count);
    this.ledRoom = new Int16Array(count);
    this.ledKind = [];
    this.leds = new THREE.InstancedMesh(geo, ledMaterial(), Math.max(1, count));
    this.leds.count = count;
    let n = 0;
    racks.forEach((rack) => {
      for (const slot of slots) {
        const big = slot.kind === 'beacon';
        this.leds.setMatrixAt(n, mat(rack.x + slot.x, 0.4 + slot.y, rack.z + slot.z, 0, 0, 0, big ? 2.2 : slot.kind === 'status' ? 1.3 : 1, big ? 2.2 : 1, big ? 2.2 : 1));
        const color = slot.kind === 'beacon' ? 0xFF3B30 : slot.kind === 'status' ? 0x3CE070 : LED_COLORS[Math.floor(Math.random() * LED_COLORS.length)];
        this.leds.setColorAt(n, new THREE.Color(color));
        seeds[n] = Math.random();
        this.ledRoom[n] = rack.room;
        this.ledKind.push(slot.kind);
        n++;
      }
    });
    geo.setAttribute('aSeed', new THREE.InstancedBufferAttribute(seeds, 1));
    this.rates = new THREE.InstancedBufferAttribute(rates, 1);
    geo.setAttribute('aRate', this.rates);
    this.group.add(this.leds);

    // 天线
    this.dishes = new THREE.InstancedMesh(dishGeometry(p), new THREE.MeshLambertMaterial({ vertexColors: true }), Math.max(1, this.rooms.length));
    this.dishes.count = this.rooms.length;
    this.dishes.frustumCulled = false;
    this.group.add(this.dishes);

    // 标志牌：agent 的标志 + 名字（画在贴图上，几间机房就几张）
    this.rooms.forEach((room) => {
      const tex = this.signTexture(room.agent, data.agentName(room.agent));
      const sign = new THREE.Mesh(new THREE.PlaneGeometry(4.2, 2.1), new THREE.MeshBasicMaterial({ map: tex }));
      sign.position.set(room.x + 2 + room.span / 2, 10.4, room.z + 2.2 + RACK.d / 2 + 0.05);
      this.group.add(sign);
      const post = new THREE.Mesh(new THREE.BoxGeometry(4.4, 2.3, 0.1), new THREE.MeshLambertMaterial({ color: p.rail }));
      post.position.copy(sign.position).add(v.set(0, 0, -0.08));
      this.group.add(post);
    });
    this.updateRates(data);
    this.tick(this.world.time, 0);
  }

  /// 机房门头的牌子：96×48 的小画布上画像素字和标志，按最近像素放大（像素风）
  signTexture(agent, name) {
    const c = document.createElement('canvas');
    c.width = 96; c.height = 48;
    const g = c.getContext('2d');
    g.fillStyle = '#3A3B42'; g.fillRect(0, 0, 96, 48);
    g.fillStyle = '#121316'; g.fillRect(2, 2, 92, 44);
    const layers = this.world.marks[agent];
    const hasMark = layers && layers.length && typeof Path2D !== 'undefined';
    if (hasMark) {
      g.save(); g.translate(40, 5); g.scale(16 / 24, 16 / 24); g.fillStyle = '#FFFFFF';
      for (const layer of layers) { g.globalAlpha = layer.opacity ?? 1; g.fill(new Path2D(layer.d), 'evenodd'); }
      g.restore();
    }
    g.globalAlpha = 1;
    g.fillStyle = '#FFFFFF';
    g.font = '12px "Pixel", -apple-system, "PingFang SC", sans-serif';
    g.textAlign = 'center'; g.textBaseline = 'middle';
    g.fillText(name, 48, hasMark ? 34 : 24, 88);
    const tex = new THREE.CanvasTexture(c);
    tex.colorSpace = THREE.SRGBColorSpace;
    tex.magFilter = THREE.NearestFilter;
    tex.minFilter = THREE.LinearFilter;
    tex.generateMipmaps = false;
    return tex;
  }

  /// 这家 agent 有几个会话在工作：灯就闪多快（空闲时慢悠悠地闪，忙起来像开了锅）
  updateRates(data) {
    if (!this.leds) return;
    const busy = new Map(), waiting = new Map();
    for (const s of data.sessions.values()) {
      if (s.activity === 'busy') busy.set(s.agent, (busy.get(s.agent) || 0) + 1);
      if (s.activity === 'waiting') waiting.set(s.agent, (waiting.get(s.agent) || 0) + 1);
    }
    for (let i = 0; i < this.leds.count; i++) {
      const room = this.rooms[this.ledRoom[i]];
      const b = busy.get(room.agent) || 0;
      const kind = this.ledKind[i];
      const base = kind === 'beacon' ? 0.7 : kind === 'status' ? 0.4 + (waiting.get(room.agent) ? 2.5 : 0) : 1.2 + Math.random() * 1.5;
      this.rates.setX(i, kind === 'activity' ? base + Math.min(14, b * 3.2) * (0.6 + Math.random() * 0.8) : base);
    }
    this.rates.needsUpdate = true;
  }

  /// 天线馈源的位置（光弧起点）
  feedPos(agent, out = new THREE.Vector3()) {
    const room = this.rooms.find(r => r.agent === agent);
    if (!room) return null;
    return out.copy(DISH_FEED).applyAxisAngle(v.set(0, 1, 0), room.yaw).add(v.set(room.dish.x, 0.4, room.dish.z));
  }

  /// 让天线对准某颗卫星（收发消息时）
  aim(agent, satelliteId) {
    const room = this.rooms.find(r => r.agent === agent);
    if (room) room.target = satelliteId;
  }

  roomCenter(agent, out = new THREE.Vector3()) {
    const room = this.rooms.find(r => r.agent === agent);
    return room ? out.set(room.x + room.w / 2, 4, room.z + room.d / 2) : null;
  }

  tick(time, dt) {
    if (!this.leds) return;
    this.leds.material.uniforms.uTime.value = time;
    const sky = this.world.sky;
    this.rooms.forEach((room, i) => {
      const target = sky && (sky.position(room.target) || sky.nearest(room.dish.x, room.dish.z));
      if (target) {
        const want = Math.atan2(target.x - room.dish.x, target.z - room.dish.z);
        let d = want - room.yaw;
        d = Math.atan2(Math.sin(d), Math.cos(d));
        room.yaw += d * (1 - Math.exp(-dt * 1.5));
      }
      this.dishes.setMatrixAt(i, tmp.makeRotationY(room.yaw).setPosition(room.dish.x, 0.4, room.dish.z));
    });
    this.dishes.instanceMatrix.needsUpdate = true;
  }

  pick(raycaster) {
    if (!this.racks) return null;
    const hits = raycaster.intersectObjects([this.racks, this.dishes, this.leds], false);
    for (const hit of hits) {
      if (hit.instanceId == null) continue;
      if (hit.object === this.racks) return this.rooms[this.rackList[hit.instanceId].room];
      if (hit.object === this.dishes) return this.rooms[hit.instanceId];
      if (hit.object === this.leds) return this.rooms[this.ledRoom[hit.instanceId]];
    }
    return null;
  }

  label(room, data) {
    let busy = 0, total = 0;
    for (const s of data.sessions.values()) if (s.agent === room.agent) { total++; if (s.activity === 'busy') busy++; }
    return { name: t('%@ 机房', data.agentName(room.agent)), sub: busy ? t('%@ 个会话 · %@ 个在工作', total, busy) : t('%@ 个会话', total) };
  }
}
