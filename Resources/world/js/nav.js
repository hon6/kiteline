// 走路寻路：把场地切成 0.5 的格子，桌子（连凳子）、玻璃墙、机房占着的格子不能走；A* 找路，再拉直成几段直线。
// 只在有人要走过去时算一次（几万个格子，几毫秒）。

const CELL = 0.5;
const PAD = 0.35;   // 人的半个身位

export class Nav {
  constructor(layout) {
    const b = layout.bounds;
    this.minX = b.minX - 8;
    this.minZ = b.minZ - 6;
    this.w = Math.ceil((b.maxX - b.minX + 16) / CELL);
    this.h = Math.ceil((b.maxZ - b.minZ + 14) / CELL);
    this.blocked = new Uint8Array(this.w * this.h);
    for (const zone of layout.zones) {
      for (const d of zone.desks) this.rect(d.x - 2.75, d.z - 3.35, d.x + 2.75, d.z + 0.75);
      this.rect(zone.x, zone.z + 0.1, zone.x + zone.w, zone.z + 0.4);   // 玻璃墙
    }
    for (const room of layout.rooms) this.rect(room.x, room.z, room.x + room.w, room.z + room.d);
    if (layout.room) {
      const r = layout.room;
      this.rect(r.minX - 1, r.minZ - 1, r.maxX + 1, r.minZ + 0.6);
      this.rect(r.minX - 1, r.maxZ - 0.6, r.maxX + 1, r.maxZ + 1);
      this.rect(r.minX - 1, r.minZ - 1, r.minX + 0.6, r.maxZ + 1);
      this.rect(r.maxX - 0.6, r.minZ - 1, r.maxX + 1, r.maxZ + 1);
    }
    if (layout.company) this.rect(layout.company.x - layout.company.w / 2, layout.company.z - 0.5, layout.company.x + layout.company.w / 2, layout.company.z + 0.7);
  }

  rect(x0, z0, x1, z1) {
    const i0 = Math.max(0, Math.floor((x0 - PAD - this.minX) / CELL)), i1 = Math.min(this.w - 1, Math.floor((x1 + PAD - this.minX) / CELL));
    const j0 = Math.max(0, Math.floor((z0 - PAD - this.minZ) / CELL)), j1 = Math.min(this.h - 1, Math.floor((z1 + PAD - this.minZ) / CELL));
    for (let j = j0; j <= j1; j++) for (let i = i0; i <= i1; i++) this.blocked[j * this.w + i] = 1;
  }

  cellOf(x, z) {
    return [Math.min(this.w - 1, Math.max(0, Math.floor((x - this.minX) / CELL))), Math.min(this.h - 1, Math.max(0, Math.floor((z - this.minZ) / CELL)))];
  }

  free(i, j) { return i >= 0 && j >= 0 && i < this.w && j < this.h && !this.blocked[j * this.w + i]; }

  /// 离 (x, z) 最近的能站的格子中心
  nearestFree(x, z) {
    const [ci, cj] = this.cellOf(x, z);
    if (this.free(ci, cj)) return { x, z };
    for (let r = 1; r < 30; r++) {
      for (let dj = -r; dj <= r; dj++) for (let di = -r; di <= r; di++) {
        if (Math.max(Math.abs(di), Math.abs(dj)) !== r) continue;
        if (this.free(ci + di, cj + dj)) return this.center(ci + di, cj + dj);
      }
    }
    return { x, z };
  }

  center(i, j) { return { x: this.minX + (i + 0.5) * CELL, z: this.minZ + (j + 0.5) * CELL }; }

  /// 两点之间能不能直着走过去（每 0.25 查一下）
  clear(a, b) {
    const len = Math.hypot(b.x - a.x, b.z - a.z);
    const steps = Math.ceil(len / 0.25);
    for (let s = 1; s < steps; s++) {
      const t = s / steps;
      const [i, j] = this.cellOf(a.x + (b.x - a.x) * t, a.z + (b.z - a.z) * t);
      if (!this.free(i, j)) return false;
    }
    return true;
  }

  /// 从 a 走到 b 的拐点（不含起点）；找不到路就直接走过去
  path(a, b) {
    const goal = this.nearestFree(b.x, b.z);
    if (this.clear(a, goal)) return [goal];
    const [si, sj] = this.cellOf(a.x, a.z), [gi, gj] = this.cellOf(goal.x, goal.z);
    const W = this.w, n = W * this.h;
    const g = new Float32Array(n).fill(Infinity), came = new Int32Array(n).fill(-1), closed = new Uint8Array(n);
    const heap = new Heap();
    const start = sj * W + si, target = gj * W + gi;
    g[start] = 0;
    heap.push(start, 0);
    const h = (i, j) => { const dx = Math.abs(i - gi), dy = Math.abs(j - gj); return dx + dy + (Math.SQRT2 - 2) * Math.min(dx, dy); };
    let found = false, guard = 0;
    while (heap.size && guard++ < 60000) {
      const cur = heap.pop();
      if (cur === target) { found = true; break; }
      if (closed[cur]) continue;
      closed[cur] = 1;
      const ci = cur % W, cj = (cur - ci) / W;
      for (let dj = -1; dj <= 1; dj++) for (let di = -1; di <= 1; di++) {
        if (!di && !dj) continue;
        const ni = ci + di, nj = cj + dj;
        if (!this.free(ni, nj) && !(ni === gi && nj === gj)) continue;
        if (di && dj && (!this.free(ci + di, cj) || !this.free(ci, cj + dj))) continue;   // 不切墙角
        const next = nj * W + ni;
        const cost = g[cur] + (di && dj ? Math.SQRT2 : 1);
        if (cost < g[next]) { g[next] = cost; came[next] = cur; heap.push(next, cost + h(ni, nj)); }
      }
    }
    if (!found) return [goal];
    const cells = [];
    for (let c = target; c !== -1 && c !== start; c = came[c]) cells.push(c);
    cells.reverse();
    const points = cells.map(c => this.center(c % W, Math.floor(c / W)));
    points[points.length - 1] = goal;
    // 拉直：能直着走到的拐点就跳过中间的
    const out = [];
    let from = a, k = 0;
    while (k < points.length) {
      let far = k;
      for (let m = points.length - 1; m > k; m--) if (this.clear(from, points[m])) { far = m; break; }
      out.push(points[far]);
      from = points[far];
      k = far + 1;
    }
    return out;
  }
}

class Heap {
  constructor() { this.items = []; this.keys = []; }
  get size() { return this.items.length; }
  push(item, key) {
    const a = this.items, k = this.keys;
    a.push(item); k.push(key);
    let i = a.length - 1;
    while (i > 0) {
      const p = (i - 1) >> 1;
      if (k[p] <= k[i]) break;
      [a[p], a[i]] = [a[i], a[p]]; [k[p], k[i]] = [k[i], k[p]];
      i = p;
    }
  }
  pop() {
    const a = this.items, k = this.keys;
    const top = a[0];
    const lastItem = a.pop(), lastKey = k.pop();
    if (a.length) {
      a[0] = lastItem; k[0] = lastKey;
      let i = 0;
      for (;;) {
        const l = i * 2 + 1, r = l + 1;
        let m = i;
        if (l < a.length && k[l] < k[m]) m = l;
        if (r < a.length && k[r] < k[m]) m = r;
        if (m === i) break;
        [a[m], a[i]] = [a[i], a[m]]; [k[m], k[i]] = [k[i], k[m]];
        i = m;
      }
    }
    return top;
  }
}
