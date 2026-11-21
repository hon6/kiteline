// AR 模式的背景：除了透明（看到桌面），还有几种用着色器画的、慢慢在动、无缝循环的场景：宇宙、天空、海面、森林、极光。
// 全是代码算出来的（没有图片和视频，不占包大小、没有版权问题、多大的屏都清楚），跟着镜头转：转头时背景像 360° 的世界一样跟着转。
// 用户自己的视频 / 图片由宿主在网页下面用原生播放器放（硬件解码、首尾衔接），这里只负责把画布藏起来。
// 背景很柔和，按屏幕 0.6 倍的分辨率画、每秒 30 帧，开销很小。

const SCENES = { space: 1, sky: 2, sea: 3, forest: 4, aurora: 5 };
export const BACKDROPS = ['none', 'space', 'sky', 'sea', 'forest', 'aurora'];

const VS = 'attribute vec2 a;void main(){gl_Position=vec4(a,0.,1.);}';
const FS = `
precision highp float;
uniform vec2 R; uniform float T; uniform vec2 V; uniform int S;
float h(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float n(vec2 p){ vec2 i = floor(p), f = fract(p); f = f * f * (3. - 2. * f);
  return mix(mix(h(i), h(i + vec2(1., 0.)), f.x), mix(h(i + vec2(0., 1.)), h(i + vec2(1., 1.)), f.x), f.y); }
float fbm(vec2 p){ float v = 0., a = .5; for (int i = 0; i < 5; i++) { v += a * n(p); p = p * 2.03 + vec2(1.7, 9.2); a *= .5; } return v; }
vec3 stars(vec2 p, float scale, float th){
  vec2 g = p * scale, i = floor(g), f = fract(g) - .5; float r = h(i);
  if (r < th) return vec3(0.);
  vec2 o = vec2(h(i + 3.1), h(i + 7.7)) - .5;
  float d = length(f - o * .7), tw = .55 + .45 * sin(T * (.6 + r * 2.) + r * 40.);
  return vec3(smoothstep(.09, 0., d) * tw) * mix(vec3(.75, .82, 1.), vec3(1., .9, .78), h(i + 1.3));
}
vec3 space(vec2 p){
  p += vec2(T * .003, 0.);
  vec3 c = mix(vec3(.008, .01, .03), vec3(.03, .02, .07), clamp(p.y * .6, 0., 1.));
  float a = fbm(p * 1.2 + vec2(T * .008, 0.)), b = fbm(p * 2.6 - vec2(0., T * .006) + 4.);
  c += vec3(.36, .12, .55) * pow(a, 3.) * 1.6 + vec3(.04, .24, .46) * pow(b, 4.) * 2.;
  c += vec3(.9, .5, .3) * pow(fbm(p * 4. + 9.), 6.) * 1.2;
  return c + stars(p, 110., .86) * .9 + stars(p + 5., 55., .9) * 1.2 + stars(p + 9., 24., .955) * 1.6;
}
vec3 sky(vec2 p){
  float y = p.y;
  vec3 c = mix(vec3(.66, .8, .95), vec3(.16, .38, .76), smoothstep(0., 1.15, y));
  vec2 q = p * vec2(1., 2.2) + vec2(T * .01, 0.);
  float cl = fbm(q * 1.5) + .5 * fbm(q * 3.4 + T * .006);
  cl = smoothstep(.5, .95, cl) * smoothstep(.0, .35, y);
  vec3 sh = mix(vec3(1.), vec3(.72, .78, .88), smoothstep(.7, 1.15, fbm(q * 1.5 + .3) + .5 * fbm(q * 3.4)));
  c = mix(c, sh, cl * .9);
  vec2 sun = vec2(-.45, .78); float d = length(p - sun);
  return c + vec3(1., .93, .78) * (.35 * exp(-d * 6.) + .9 * smoothstep(.022, .016, d)) * (1. - cl * .8);
}
vec3 sea(vec2 p){
  float hz = .42;
  vec3 s = mix(vec3(.99, .63, .42), vec3(.15, .19, .42), smoothstep(hz, 1.2, p.y));
  vec2 sun = vec2(.38, hz + .1); float d = length(p - sun);
  s += vec3(1., .7, .4) * .55 * exp(-d * 4.5) + vec3(1., .88, .65) * smoothstep(.05, .04, d);
  float cl = fbm(vec2(p.x * 1.4 + T * .006, p.y * 6.));
  s = mix(s, vec3(1., .74, .6), smoothstep(.62, 1., cl) * .35 * smoothstep(hz + .05, hz + .35, p.y));
  if (p.y > hz) return s;
  float dep = hz - p.y;
  vec2 wp = vec2(p.x / (dep + .035), 1. / (dep + .035)) * .22;
  float wv = fbm(wp * vec2(2.2, 1.) + vec2(0., T * .32)) + .5 * n(wp * 9. + vec2(T * .5, 0.));
  vec3 w = mix(vec3(.62, .44, .42), vec3(.02, .06, .12), smoothstep(0., .32, dep));
  w += (wv - .6) * .14;
  float streak = exp(-abs(p.x - sun.x) * (2.5 + dep * 22.)) * smoothstep(.55, .95, wv);
  w += vec3(1., .74, .45) * streak * 1.3;
  return mix(w, s * .85, smoothstep(.06, 0., dep) * .6);
}
vec3 birds(vec2 p, vec3 c){
  // 几只鸟从画面上方慢慢飞过，翅膀一上一下地扇（三只一小群，错开）
  for (int i = 0; i < 9; i++) {
    float fi = float(i), g = floor(fi / 3.), r = h(vec2(fi, 2.));
    float sp = .028 + .012 * h(vec2(g, 1.));
    vec2 b = vec2(mod(T * sp + g * 1.05 + fi * .05, 3.2) - 1.6 + mod(fi, 3.) * .035,
                  .66 + .2 * h(vec2(g, 4.)) + mod(fi, 3.) * .022 + .015 * sin(T * .6 + fi));
    float size = .010 + .004 * r;
    vec2 d = (p - b) / size;
    float flap = sin(T * (6. + r * 2.) + fi * 2.1);
    float span = 1.5;
    float wing = d.y - abs(d.x) * (.55 * flap) + .12 * d.x * d.x * flap;
    float thick = .28 * (1. - abs(d.x) / span) + .05;
    float m = smoothstep(thick, thick * .4, abs(wing)) * step(abs(d.x), span);
    c = mix(c, vec3(.16, .17, .19), m * .9);
  }
  return c;
}
vec3 forest(vec2 p){
  // 晨光里的林子：天是暖白到淡蓝，右上方有太阳，光柱从树缝里斜着照进来
  vec3 c = mix(vec3(.95, .93, .82), vec3(.55, .72, .82), smoothstep(.3, 1.2, p.y));
  vec2 sun = vec2(.5, .95);
  c += vec3(1., .88, .62) * .4 * exp(-length(p - sun) * 3.);
  c = birds(p, c);
  for (int i = 0; i < 5; i++) {
    float fi = float(i), far = 1. - fi / 4.;
    // 近处的树随风轻轻摆
    float sway = .004 * fi * sin(T * .9 + p.x * 3. + fi) * max(0., p.y - .1);
    float x = (p.x + sway) * (.7 + fi * .32) + fi * 7.3, dens = 5.2 - fi * .65;
    float k = floor(x * dens), fx = fract(x * dens), r = h(vec2(k, fi));
    float base = .37 - fi * .075 + .03 * n(vec2(x * .7, fi));
    float th = .13 + .19 * r + fi * .03;
    float edge = fbm(vec2(x * 34., p.y * 34.) + fi * 3.) - .5;   // 参差的叶子边
    float prof = 1. - abs(fx - .5) * 2., top;
    if (r > .64) {
      // 阔叶树：一团团的圆冠 + 树干
      float dome = sqrt(max(0., 1. - pow((fx - .5) * 2.1, 2.)));
      float lumps = .1 * n(vec2(x * 30., p.y * 22.));
      top = base + th * .3 + th * .7 * dome + edge * .05 + lumps * th;
      if (abs(fx - .5) < .045 && p.y < base + th * .4) top = max(top, p.y + .001);
    } else {
      // 针叶树：一层层往外伸的枝叶
      float tier = fract((p.y - base) / th * 5.5);
      top = base + th * (prof * 1.18 - .22 * tier * (1. - prof * .6)) + edge * .035 * (1. + fi * .6);
    }
    float inside = max(step(p.y, top), step(p.y, base + .015));
    // 叶子：深浅不一的斑驳绿，树梢迎光亮一点；远处的被雾冲淡
    float lt = fbm(vec2(x * 46., p.y * 46.) + fi * 5.);
    vec3 leaf = mix(vec3(.04, .13, .06), vec3(.2, .38, .14), lt);
    leaf *= .55 + .7 * smoothstep(base, base + th, p.y);
    leaf += vec3(.35, .3, .1) * pow(lt, 3.) * smoothstep(base + th * .6, base + th, p.y) * (1. - far * .5);
    vec3 col = mix(leaf, c * .93, far * .78);
    c = mix(c, col, inside);
    float fog = fbm(vec2(x * .7 + T * .015 * (1. + fi), p.y * 3. + fi));
    c = mix(c, vec3(.9, .91, .86), smoothstep(.5, .92, fog) * .2 * far * smoothstep(base + th + .12, base, p.y));
  }
  // 光柱 + 光柱里漂浮的光点
  float beam = pow(max(0., sin((p.x * .55 - p.y * .45) * 7. + fbm(vec2(p.x * 1.5, T * .03)) * 2.5)), 10.);
  c += vec3(1., .93, .72) * beam * .13 * smoothstep(.05, .9, p.y);
  vec2 g = vec2(p.x * 18. + T * .04, p.y * 18. - T * .06), i = floor(g);
  float fl = h(i), fd = length(fract(g) - .5 - (vec2(h(i + 2.), h(i + 5.)) - .5) * .6 - vec2(sin(T * .5 + fl * 9.), cos(T * .4 + fl * 7.)) * .15);
  c += vec3(1., .95, .75) * smoothstep(.05, 0., fd) * step(.9, fl) * beam * 2.5;
  return c;
}
vec3 aurora(vec2 p){
  vec3 c = mix(vec3(.01, .02, .05), vec3(.02, .05, .1), clamp(p.y * .5, 0., 1.));
  c += stars(p, 90., .9) * .8;
  for (int i = 0; i < 3; i++) {
    float fi = float(i);
    float y = .52 + .11 * fi + .07 * sin(p.x * 1.2 + T * .05 + fi * 2.) + .06 * fbm(vec2(p.x * 1.8 + T * .02, fi * 4.));
    float d = p.y - y;
    float cur = exp(-abs(d) * (d > 0. ? 5. : 22.)) * (.4 + .6 * fbm(vec2(p.x * 7. + T * .08, fi * 3.)));
    cur *= .6 + .4 * pow(n(vec2(p.x * 38. + T * .3, fi)), 2.);
    c += mix(vec3(.08, .95, .55), vec3(.55, .25, .9), smoothstep(0., .18, d)) * cur * (.55 - fi * .1);
  }
  float ridge = .17 + .07 * fbm(vec2(p.x * 1.6, 3.)) + .03 * n(vec2(p.x * 9., 1.));
  return mix(c, vec3(.01, .015, .025), step(p.y, ridge));
}
void main(){
  vec2 p = vec2((gl_FragCoord.x - R.x * .5) / R.y - V.x * .9, gl_FragCoord.y / R.y + V.y * .7);
  vec3 c = S == 1 ? space(p) : S == 2 ? sky(p) : S == 3 ? sea(p) : S == 4 ? forest(p) : aurora(p);
  vec2 q = gl_FragCoord.xy / R;
  c *= .82 + .18 * pow(16. * q.x * q.y * (1. - q.x) * (1. - q.y), .2);
  gl_FragColor = vec4(c, 1.);
}`;

export class Backdrop {
  constructor(canvas, ar) {
    this.canvas = canvas; this.ar = ar; this.scene = 'none'; this.last = 0;
    const gl = canvas.getContext('webgl', { alpha: false, antialias: false, premultipliedAlpha: false, powerPreference: 'low-power' });
    this.gl = gl;
    if (!gl) return;
    const sh = (type, src) => { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) console.warn(gl.getShaderInfoLog(s)); return s; };
    const pr = gl.createProgram();
    gl.attachShader(pr, sh(gl.VERTEX_SHADER, VS)); gl.attachShader(pr, sh(gl.FRAGMENT_SHADER, FS)); gl.linkProgram(pr); gl.useProgram(pr);
    gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const a = gl.getAttribLocation(pr, 'a'); gl.enableVertexAttribArray(a); gl.vertexAttribPointer(a, 2, gl.FLOAT, false, 0, 0);
    this.u = { R: gl.getUniformLocation(pr, 'R'), T: gl.getUniformLocation(pr, 'T'), V: gl.getUniformLocation(pr, 'V'), S: gl.getUniformLocation(pr, 'S') };
    this.t0 = performance.now();
    const loop = (now) => { requestAnimationFrame(loop); this.draw(now); };
    requestAnimationFrame(loop);
  }

  set(name) {
    this.scene = SCENES[name] ? name : 'none';
    this.canvas.hidden = this.scene === 'none';
    document.body.classList.toggle('has-bg', this.scene !== 'none');
    this.last = 0;
  }

  /// 自测用：不等 requestAnimationFrame，马上画一帧
  draw(now = performance.now(), force = false) {
    const gl = this.gl;
    if (!gl || this.scene === 'none' || (!force && (!this.ar.visible || now - this.last < 33))) return;
    this.last = now;
    // 森林有树叶细节，画得清楚一点；别的场景很柔和，0.6 倍就够
    const k = this.scene === 'forest' ? 0.85 : 0.6;
    const w = Math.round(innerWidth * k), hgt = Math.round(innerHeight * k);
    if (this.canvas.width !== w || this.canvas.height !== hgt) { this.canvas.width = w; this.canvas.height = hgt; gl.viewport(0, 0, w, hgt); }
    gl.uniform2f(this.u.R, w, hgt);
    gl.uniform1f(this.u.T, (now - this.t0) / 1000);
    gl.uniform2f(this.u.V, this.ar.cur.yaw, this.ar.cur.pitch);
    gl.uniform1i(this.u.S, SCENES[this.scene]);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }
}
