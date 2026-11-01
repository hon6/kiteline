// 特效：消息的光弧（机房天线 → 卫星 → 会话的电脑；你发的话反过来），人来人走的光柱。
// 光弧是一条面向镜头的光带，位置在顶点着色器里按二次贝塞尔算：卫星一直在动，每帧只改三个端点，不重建几何体。

import * as THREE from '../vendor/three.module.min.js';
import { radialTexture } from './parts.js';

const ARC_VERTEX = /* glsl */`
  uniform vec3 p0;
  uniform vec3 p1;
  uniform vec3 p2;
  uniform float uWidth;
  uniform float uHead;
  uniform float uTail;
  varying float vT;
  varying float vSide;
  vec3 bez(float t) { float u = 1.0 - t; return u * u * p0 + 2.0 * u * t * p1 + t * t * p2; }
  void main() {
    float t = position.x + 0.5;
    vT = t;
    vSide = position.y * 2.0;
    vec3 c = bez(t);
    vec3 tangent = bez(min(t + 0.01, 1.0)) - bez(max(t - 0.01, 0.0));
    vec4 view = viewMatrix * vec4(c, 1.0);
    vec3 vt = normalize((viewMatrix * vec4(tangent, 0.0)).xyz + vec3(1e-5));
    vec3 side = normalize(cross(vt, normalize(view.xyz)));
    float head = smoothstep(uHead - uTail, uHead, t) * (1.0 - smoothstep(uHead, uHead + 0.03, t));
    float w = uWidth * (0.45 + 1.4 * head);
    view.xyz += side * position.y * w;
    gl_Position = projectionMatrix * view;
  }`;

const ARC_FRAGMENT = /* glsl */`
  uniform vec3 uColor;
  uniform float uHead;
  uniform float uTail;
  uniform float uFade;
  uniform float uDash;
  uniform float uTime;
  varying float vT;
  varying float vSide;
  void main() {
    float trail = smoothstep(uHead - uTail, uHead, vT) * (1.0 - smoothstep(uHead, uHead + 0.012, vT));
    float path = 0.35 * (1.0 - step(uHead, vT));
    float core = pow(max(0.0, 1.0 - abs(vSide)), 1.6);
    float dash = uDash > 0.0 ? step(0.45, fract(vT * uDash - uTime * 1.6)) : 1.0;
    float a = (trail + path) * core * uFade * dash;
    gl_FragColor = vec4(mix(uColor, vec3(1.0), trail * core * 0.55) * (1.0 + trail * 1.5), a);
  }`;

const ease = (u) => (u < 0.5 ? 4 * u * u * u : 1 - Math.pow(-2 * u + 2, 3) / 2);
const v = new THREE.Vector3();

export class Effects {
  constructor(world) {
    this.world = world;
    this.group = new THREE.Group();
    world.scene.add(this.group);
    this.arcGeo = new THREE.PlaneGeometry(1, 1, 72, 1);
    this.glowTex = radialTexture();
    this.pool = [];
    this.active = [];
  }

  makeArc() {
    const material = new THREE.ShaderMaterial({
      uniforms: {
        p0: { value: new THREE.Vector3() }, p1: { value: new THREE.Vector3() }, p2: { value: new THREE.Vector3() },
        uWidth: { value: 0.35 }, uHead: { value: 0 }, uTail: { value: 0.32 }, uFade: { value: 1 },
        uColor: { value: new THREE.Color() }, uDash: { value: 0 }, uTime: { value: 0 },
      },
      vertexShader: ARC_VERTEX,
      fragmentShader: ARC_FRAGMENT,
      transparent: true,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
      side: THREE.DoubleSide,
    });
    const mesh = new THREE.Mesh(this.arcGeo, material);
    mesh.frustumCulled = false;
    mesh.renderOrder = 5;
    const glow = new THREE.Sprite(new THREE.SpriteMaterial({ map: this.glowTex, transparent: true, depthWrite: false, blending: THREE.AdditiveBlending }));
    glow.renderOrder = 6;
    return { mesh, glow };
  }

  /// 一段光弧：from / to 是取位置的函数（端点会动）；onLand 在光头到达时调
  arc(from, to, { color = 0xD97757, duration = 1.0, width = 0.6, dash = 0, lift = 0.35, onLand } = {}) {
    const item = this.pool.pop() || this.makeArc();
    const u = item.mesh.material.uniforms;
    u.uColor.value.set(color);
    u.uWidth.value = width;
    u.uDash.value = dash;
    u.uHead.value = 0;
    u.uFade.value = 1;
    item.glow.material.color.set(color);
    Object.assign(item, { from, to, start: this.world.time, duration, lift, onLand, landed: false });
    this.group.add(item.mesh, item.glow);
    this.active.push(item);
    this.world.invalidate();
    return item;
  }

  /// 机房 → 卫星 → 电脑（agent 的回复）或反过来（你发的话），到了以后调 onLand
  relay(points, { color, onLand, onHop } = {}) {
    const hops = [];
    for (let i = 0; i + 1 < points.length; i++) hops.push([points[i], points[i + 1]]);
    const run = (index) => {
      if (index >= hops.length) { onLand?.(); return; }
      const [a, b] = hops[index];
      this.arc(a, b, { color, onLand: () => { onHop?.(index); run(index + 1); } });
    };
    run(0);
  }

  /// 光柱：人来（从天上掉下来时）、人走（升上去）
  beam(pos, color = 0xD97757) {
    const geo = new THREE.CylinderGeometry(1.4, 1.4, 30, 20, 1, true);
    geo.translate(0, 15, 0);
    const material = new THREE.ShaderMaterial({
      uniforms: { uColor: { value: new THREE.Color(color) }, uFade: { value: 1 } },
      vertexShader: 'varying float vY; void main(){ vY = position.y / 30.0; gl_Position = projectionMatrix * modelViewMatrix * vec4(position,1.0); }',
      fragmentShader: 'uniform vec3 uColor; uniform float uFade; varying float vY; void main(){ gl_FragColor = vec4(uColor, (1.0 - vY) * 0.45 * uFade); }',
      transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, side: THREE.DoubleSide,
    });
    const mesh = new THREE.Mesh(geo, material);
    mesh.position.copy(pos);
    this.group.add(mesh);
    this.active.push({ beam: mesh, start: this.world.time, duration: 1.4 });
  }

  get busy() { return this.active.length > 0; }

  tick(time) {
    const keep = [];
    for (const item of this.active) {
      const age = time - item.start;
      if (item.beam) {
        const u = age / item.duration;
        item.beam.material.uniforms.uFade.value = Math.max(0, 1 - u);
        item.beam.scale.set(1 - u * 0.6, 1, 1 - u * 0.6);
        if (u >= 1) { this.group.remove(item.beam); item.beam.geometry.dispose(); item.beam.material.dispose(); } else keep.push(item);
        continue;
      }
      // 光弧
      const a = item.from(), b = item.to();
      if (!a || !b) { this.release(item); continue; }
      const u = item.mesh.material.uniforms;
      u.uTime.value = time;
      u.p0.value.copy(a);
      u.p2.value.copy(b);
      u.p1.value.copy(a).add(b).multiplyScalar(0.5);
      u.p1.value.y += a.distanceTo(b) * item.lift;
      const travel = Math.min(1, age / item.duration);
      const head = ease(travel);
      u.uHead.value = head;
      // 光头的光晕
      const w = 1 - head;
      item.glow.position.set(
        w * w * a.x + 2 * w * head * u.p1.value.x + head * head * b.x,
        w * w * a.y + 2 * w * head * u.p1.value.y + head * head * b.y,
        w * w * a.z + 2 * w * head * u.p1.value.z + head * head * b.z);
      item.glow.scale.setScalar(item.mesh.material.uniforms.uWidth.value * 11);
      if (travel >= 1 && !item.landed) { item.landed = true; item.onLand?.(); }
      // 到了以后整条慢慢淡掉
      const fade = travel >= 1 ? Math.max(0, 1 - (age - item.duration) / 0.6) : 1;
      u.uFade.value = fade;
      item.glow.material.opacity = travel >= 1 ? fade * 0.6 : 1;
      if (fade <= 0) this.release(item); else keep.push(item);
    }
    this.active = keep;
  }

  release(item) {
    this.group.remove(item.mesh, item.glow);
    if (this.pool.length < 24) this.pool.push(item);
    else { item.mesh.material.dispose(); item.glow.material.dispose(); }
  }
}
