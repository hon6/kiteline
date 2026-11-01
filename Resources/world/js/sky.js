// 天上：每台设备一颗卫星（绕整片场地慢慢飞，离线的亮红灯、慢慢翻滚）。

import * as THREE from '../vendor/three.module.min.js';
import { satelliteBodyGeometry, solarPanelGeometry, solarPanelTexture, radialTexture } from './parts.js';

const v = new THREE.Vector3();

export class Sky {
  constructor(world) {
    this.world = world;
    this.group = new THREE.Group();
    world.scene.add(this.group);
    this.sats = [];
    this.bodyGeo = satelliteBodyGeometry();
    this.panelGeo = solarPanelGeometry();
    this.panelMat = new THREE.MeshLambertMaterial({ map: solarPanelTexture() });
    this.glowTex = radialTexture();
  }

  build(layout, data) {
    for (const child of [...this.group.children]) {
      this.group.remove(child);
      if (child.userData.own) { child.geometry?.dispose(); child.material?.dispose?.(); }
    }
    this.layout = layout;
    const b = layout.bounds;
    // 卫星
    for (const sat of this.sats) sat.beacon.material.dispose();
    this.bodyMat ??= new THREE.MeshLambertMaterial({ vertexColors: true });
    const bodyMat = this.bodyMat;
    this.sats = layout.satellites.map((params) => {
      const root = new THREE.Group();
      const body = new THREE.Mesh(this.bodyGeo, bodyMat);
      const panels = new THREE.Mesh(this.panelGeo, this.panelMat);
      body.userData.satellite = params.id;
      panels.userData.satellite = params.id;
      const beacon = new THREE.Sprite(new THREE.SpriteMaterial({ map: this.glowTex, color: 0x3CE070, transparent: true, depthWrite: false, blending: THREE.AdditiveBlending }));
      beacon.scale.setScalar(2.4);
      beacon.position.set(0.45, 1.6, 0.3);
      beacon.userData.own = true;
      root.add(body, panels, beacon);
      root.scale.setScalar(1.05);
      this.group.add(root);
      return { ...params, root, body, panels, beacon, pos: new THREE.Vector3(), pulse: -10 };
    });
    this.update(data);
  }

  update(data) {
    for (const sat of this.sats) {
      const source = data.sources.get(sat.id);
      sat.online = !source || source.online;
      sat.beacon.material.color.set(sat.online ? 0x3CE070 : 0xFF3B30);
    }
  }

  /// 卫星此刻在哪
  position(id) {
    const sat = this.sats.find(s => s.id === id);
    return sat ? sat.pos : null;
  }

  nearest(x, z) {
    let best = null, d = Infinity;
    for (const s of this.sats) { const dd = (s.pos.x - x) ** 2 + (s.pos.z - z) ** 2; if (dd < d) { d = dd; best = s.pos; } }
    return best;
  }

  pulse(id) {
    const sat = this.sats.find(s => s.id === id);
    if (sat) sat.pulse = this.world.time;
  }

  tick(time) {
    const b = this.layout?.bounds;
    if (!b) return;
    for (const sat of this.sats) {
      const a = sat.phase + sat.dir * (time / sat.period) * Math.PI * 2;
      sat.pos.set(b.cx + Math.cos(a) * sat.rx, sat.altitude + Math.sin(time * 0.4 + sat.phase) * 0.8, b.cz + Math.sin(a) * sat.rz);
      sat.root.position.copy(sat.pos);
      // 机头朝飞行方向；离线的慢慢翻滚
      sat.root.rotation.set(sat.online ? 0.12 * Math.sin(time * 0.3 + sat.phase) : time * 0.25, -a * sat.dir + (sat.dir > 0 ? 0 : Math.PI), sat.online ? 0 : time * 0.17);
      const since = time - sat.pulse;
      const flash = since >= 0 && since < 1.2 ? 1 - since / 1.2 : 0;
      const blink = sat.online ? 0.55 + 0.45 * Math.max(0, Math.sin(time * 3 + sat.phase)) : (Math.sin(time * 6) > 0 ? 1 : 0.15);
      sat.beacon.material.opacity = Math.min(1, blink + flash);
      sat.beacon.scale.setScalar(2.4 + flash * 4);
    }
  }

  pick(raycaster) {
    const hits = raycaster.intersectObjects(this.sats.flatMap(s => [s.body, s.panels]), false);
    return hits.length ? hits[0].object.userData.satellite : null;
  }
}
