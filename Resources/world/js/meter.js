// 公司墙上的 token 计量牌：办公区和机房之间一面墙，墙上一块像素点阵屏（每个像素是一颗 LED 灯珠），
// 写着今天一共用了多少 token、输出多少、花了多少钱、请求了几次；新数字来了像里程表一样滚上去。
// 屏上的内容先画在 192×56 的小画布上（像素字），着色器把每个像素画成一颗圆灯珠，远了灯珠比像素还小时直接合成整块颜色，不闪。

import * as THREE from '../vendor/three.module.min.js';
import { mat } from './parts.js';
import { t } from './i18n.js';
import { WALL_H } from './office.js';

const W = 192, H = 56;
/// 计量屏多宽（世界单位）：walls.js 按它在两边挂标语
export const SCREEN_W = 17.5;
const ease = (u) => 1 - Math.pow(1 - u, 3);

function compact(n) {
  if (n >= 1e9) return (n / 1e9).toFixed(2) + 'B';
  if (n >= 1e6) return (n / 1e6).toFixed(1) + 'M';
  if (n >= 1e3) return (n / 1e3).toFixed(1) + 'K';
  return String(Math.round(n));
}

function ledMaterial(map) {
  return new THREE.ShaderMaterial({
    uniforms: { map: { value: map }, uRes: { value: new THREE.Vector2(W, H) } },
    vertexShader: 'varying vec2 vUv; void main(){ vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }',
    fragmentShader: /* glsl */`
      uniform sampler2D map;
      uniform vec2 uRes;
      varying vec2 vUv;
      void main() {
        vec2 cell = vUv * uRes;
        vec3 c = texture2D(map, (floor(cell) + 0.5) / uRes).rgb;
        float lit = step(0.04, max(c.r, max(c.g, c.b)));
        vec2 f = fract(cell) - 0.5;
        float d = length(f);
        float bead = 1.0 - smoothstep(0.32, 0.42, d);
        // 灯珠比屏幕像素还小时（离得远）：不画圆点，整块颜色
        float far = smoothstep(0.35, 0.9, max(fwidth(cell.x), fwidth(cell.y)));
        bead = mix(bead, 0.8, far);
        vec3 off = vec3(0.075, 0.07, 0.065);
        vec3 col = mix(off, c * 1.25, lit) * bead + vec3(0.015);
        gl_FragColor = vec4(col, 1.0);
        #include <colorspace_fragment>
      }`,
  });
}

export class Meter {
  constructor(world) {
    this.world = world;
    this.group = new THREE.Group();
    world.scene.add(this.group);
    this.canvas = Object.assign(document.createElement('canvas'), { width: W, height: H });
    this.texture = new THREE.CanvasTexture(this.canvas);
    this.texture.colorSpace = THREE.SRGBColorSpace;
    this.texture.magFilter = THREE.NearestFilter;
    this.texture.minFilter = THREE.NearestFilter;
    this.texture.generateMipmaps = false;
    this.shown = { tokens: 0, output: 0, cost: 0, requests: 0 };
    this.from = { ...this.shown };
    this.target = null;
    this.rollAt = -10;
    this.drawn = '';
  }

  build(layout, palette) {
    for (const child of [...this.group.children]) { this.group.remove(child); child.geometry?.dispose(); if (child.material !== this.screen?.material) child.material?.dispose?.(); }
    const c = layout.company;
    if (!c) return;
    // 墙：一面深色墙（顶上一道压顶），和项目区的待办墙一样高；屏挂中间。门、两边的标语、挂钟在 walls.js
    const wall = new THREE.Mesh(new THREE.BoxGeometry(c.w, WALL_H, 0.6), new THREE.MeshLambertMaterial({ color: palette.platform }));
    wall.position.set(c.x, WALL_H / 2, c.z);
    const cap = new THREE.Mesh(new THREE.BoxGeometry(c.w + 0.4, 0.35, 0.9), new THREE.MeshLambertMaterial({ color: palette.rail }));
    cap.position.set(c.x, WALL_H + 0.17, c.z);
    const bw = Math.min(c.w - 2, SCREEN_W), bh = bw * H / W;
    const frame = new THREE.Mesh(new THREE.BoxGeometry(bw + 0.5, bh + 0.5, 0.3), new THREE.MeshLambertMaterial({ color: 0x111215 }));
    frame.position.set(c.x, 3.4, c.z + 0.4);
    this.screen = new THREE.Mesh(new THREE.PlaneGeometry(bw, bh), this.screenMat ??= ledMaterial(this.texture));
    this.screen.position.set(c.x, 3.4, c.z + 0.56);
    this.group.add(wall, cap, frame, this.screen);
    this.draw(true);
  }

  /// 今日用量（主程序每分钟给一次）：{totals: {input, output, cacheRead, cacheWrite, cost, requests}}
  apply(usage) {
    const tot = usage?.totals || {};
    const tokens = (tot.input || 0) + (tot.output || 0) + (tot.cacheRead || 0) + (tot.cacheWrite || 0);
    const next = { tokens, output: tot.output || 0, cost: tot.cost || 0, requests: tot.requests || 0 };
    if (this.target && Object.keys(next).every(k => next[k] === this.target[k])) return;
    this.from = { ...this.shown };
    this.target = next;
    this.rollAt = this.world.time;
  }

  tick(time) {
    if (!this.target) return;
    const u = Math.min(1, (time - this.rollAt) / 1.6);
    for (const k of Object.keys(this.shown)) this.shown[k] = this.from[k] + (this.target[k] - this.from[k]) * ease(u);
    this.draw(false);
  }

  draw(force) {
    const s = this.shown;
    const big = Math.round(s.tokens).toLocaleString('en-US');
    const line = `${t('输出')} ${compact(s.output)}  ${t('花费')} $${s.cost.toFixed(s.cost >= 100 ? 0 : 2)}  ${t('请求')} ${Math.round(s.requests)}`;
    const sig = big + '|' + line;
    if (!force && sig === this.drawn) return;
    this.drawn = sig;
    const g = this.canvas.getContext('2d');
    g.clearRect(0, 0, W, H);
    g.fillStyle = '#000'; g.fillRect(0, 0, W, H);
    g.textBaseline = 'top';
    g.font = '12px "Pixel", -apple-system, sans-serif';
    g.fillStyle = '#FFB020';
    g.fillText(t('今日 Token'), 3, 1);
    g.fillStyle = '#5E6470';
    const tag = 'KITELINE';
    g.fillText(tag, W - 3 - g.measureText(tag).width, 1);
    // 大数字：像素字放大两倍，主题色
    g.font = '24px "Pixel", -apple-system, sans-serif';
    g.fillStyle = '#' + new THREE.Color(this.world.brand).getHexString();
    const width = g.measureText(big).width;
    g.fillText(big, Math.max(3, (W - width) / 2), 15, W - 6);
    g.font = '12px "Pixel", -apple-system, sans-serif';
    g.fillStyle = '#C9CDD6';
    g.fillText(line, 3, 42, W - 6);
    this.texture.needsUpdate = true;
  }
}
