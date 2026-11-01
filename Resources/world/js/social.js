// agent 之间发消息（SendMessage）：几个人站起来面对面交谈，聊一阵坐回去对着屏幕干活，再站起来接着聊，直到一阵子没往来。
// 先由开口的人（发消息的）起身走过去，被找的人坐着接着干活；走过去的人到了、开口说第一句，被找的人才站起来回话（10-27）。
// 在同一排、隔得不远就在各自凳子后面站起来转向对方；不在一排的走到收信人那边排成一排。
// 两个人：面对面轮流说。三个以上：两头的人朝里，中间的人一会儿转左一会儿转右；说话的人双手比划，听的人点头。
// 说话时头顶冒出那条消息的摘要（「对「B」说」），没有新内容就冒「…」。

import { yawToward } from './office.js';

const NEAR = 15;          // 同一排、都在这么近就不走动
const BEAT = 2.8;         // 一句话多长
const TALK = 13;          // 一轮交谈最短多久
const WORK = 9;           // 坐回去干活多久
const ACTIVE = 80;        // 最后一条往来之后多久散场（秒）
const MAX = 5;

export class Social {
  constructor(world) {
    this.world = world;
    this.groups = [];
  }

  /// 这个人正在聊天
  busy(key) { return this.groups.some(g => g.members.includes(key)); }

  /// 来了一条：from 对 to 说了 summary
  message(link) {
    const office = this.world.office;
    if (!office.has(link.from) || !office.has(link.to) || link.from === link.to) return;
    this.world.board?.cancel(link.from);
    this.world.board?.cancel(link.to);
    const now = this.world.time;
    const touching = this.groups.filter(g => g.members.includes(link.from) || g.members.includes(link.to));
    let g = touching[0];
    for (const other of touching.slice(1)) {   // 两拨人因为这条消息连起来了：并成一拨
      for (const k of other.members) if (!g.members.includes(k) && g.members.length < MAX) g.members.push(k);
      g.queue.push(...other.queue);
      this.dissolve(other, false);
    }
    if (!g) {
      g = { members: [], queue: [], phase: 'gather', since: now, last: now, beat: -1, beatAt: 0, host: link.to };
      this.groups.push(g);
    }
    for (const k of [link.from, link.to]) if (!g.members.includes(k) && g.members.length < MAX) g.members.push(k);
    g.last = now;
    g.queue.push({ from: link.from, to: link.to, text: link.summary || '' });
    // 正坐着干活时来了新消息：站起来接着聊
    if (g.phase === 'work' && now - g.since > 2) this.phase(g, 'gather');
    this.arrange(g);
  }

  /// 每个人站哪：都在附近就各站各的凳子后面，否则走到收信人那边排一排
  arrange(g) {
    const office = this.world.office;
    const host = office.aislePos(g.host) || office.aislePos(g.members[0]);
    const near = g.members.every(k => {
      const p = office.aislePos(k);
      return p && Math.abs(p.z - host.z) < 0.5 && Math.abs(p.x - host.x) < NEAR;
    });
    g.spots = new Map();
    let order;
    if (near) {
      for (const k of g.members) g.spots.set(k, null);
      // 按两头最远的连线排先后
      const pos = g.members.map(k => ({ k, p: office.aislePos(k) }));
      let a = pos[0], b = pos[pos.length - 1], far = -1;
      for (const x of pos) for (const y of pos) { const d = Math.hypot(x.p.x - y.p.x, x.p.z - y.p.z); if (d > far) { far = d; a = x; b = y; } }
      const ax = b.p.x - a.p.x, az = b.p.z - a.p.z;
      order = pos.sort((x, y) => ((x.p.x - a.p.x) * ax + (x.p.z - a.p.z) * az) - ((y.p.x - a.p.x) * ax + (y.p.z - a.p.z) * az)).map(x => x.k);
    } else {
      // 收信人那排工位后面的过道里，左右排开
      order = [...g.members].sort((x, y) => office.aislePos(x).x - office.aislePos(y).x);
      const n = order.length;
      order.forEach((k, i) => g.spots.set(k, { x: host.x + (i - (n - 1) / 2) * 1.9, z: host.z + 0.7 }));
    }
    g.order = order;
  }

  phase(g, name) {
    g.phase = name;
    g.since = this.world.time;
    g.beat = -1;
    g.beatAt = this.world.time;
  }

  dissolve(g, sit = true) {
    if (g.holding) this.world.voice?.stop();
    if (sit) for (const k of g.members) this.world.office.wantSit(k);
    this.groups = this.groups.filter(x => x !== g);
  }

  tick(time) {
    const office = this.world.office;
    for (const g of [...this.groups]) {
      g.members = g.members.filter(k => office.has(k));
      if (g.members.length < 2) { this.dissolve(g); continue; }
      if (!g.order || g.order.length !== g.members.length) this.arrange(g);
      const active = time - g.last < ACTIVE || g.queue.length > 0;
      if (g.phase === 'gather') {
        // 开口的人（有话要说的）先起身走过去；被找的人坐着等，走过去的都到了、开口了再站起来回话
        const callers = g.members.filter(k => g.queue.some(m => m.from === k));
        if (!callers.length) callers.push(g.order?.[0] || g.members[0]);
        for (const k of callers) office.wantStand(k, g.spots.get(k));
        // 已经到了的先转过来对着旁边的人（坐着的人记下朝向，站起来时正好对着说话的人）
        this.faceNeighbors(g, null);
        if (callers.every(k => office.arrived(k)) || time - g.since > 20) {
          for (const k of g.members) if (!callers.includes(k)) office.wantStand(k, g.spots.get(k));
          this.phase(g, 'talk');
        }
      } else if (g.phase === 'talk') {
        // 正在念一句（朗读）：念完才轮到下一句
        if ((time - g.beatAt >= BEAT || g.beat < 0) && !g.holding) this.nextBeat(g, time);
        const long = Math.max(TALK, (g.queue.length + 1) * BEAT);
        if (time - g.since > long && !g.queue.length && !g.holding) {
          for (const k of g.members) office.gesture(k, null);
          if (active) this.phase(g, 'work');
          else { this.dissolve(g); continue; }
        }
      } else if (g.phase === 'work') {
        for (const k of g.members) office.wantSit(k);
        if (time - g.since > WORK) {
          if (active) { this.arrange(g); this.phase(g, 'gather'); }
          else this.dissolve(g);
        }
      }
    }
  }

  /// 下一句：两个人轮流说；三个以上按相邻的两人一对从左到右再回来，每对各说一句
  nextBeat(g, time) {
    const office = this.world.office;
    const order = g.order, n = order.length;
    g.beat++;
    g.beatAt = time;
    let pair;
    if (n === 2) pair = g.beat % 2 ? [order[1], order[0]] : [order[0], order[1]];
    else {
      const pairs = [];
      for (let i = 0; i < n - 1; i++) pairs.push([i, i + 1]);
      for (let i = n - 2; i > 0; i--) pairs.push([i - 1, i]);   // 再从右往左
      const [a, b] = pairs[Math.floor(g.beat / 2) % pairs.length];
      // 每对先让靠中间的那个说（中间的人转过来、双手比划），再换另一个
      const inner = (i) => i > 0 && i < n - 1;
      const first = inner(a) && !inner(b) ? a : inner(b) && !inner(a) ? b : a;
      const second = first === a ? b : a;
      pair = g.beat % 2 ? [order[second], order[first]] : [order[first], order[second]];
    }
    // 有排着的话：谁说过要说的先说
    const queued = g.queue.findIndex(m => g.members.includes(m.from));
    if (queued >= 0 && g.beat % 2 === 0) {
      const m = g.queue[queued];
      if (g.members.includes(m.to)) pair = [m.from, m.to];
    }
    const [speaker, listener] = pair;
    this.faceNeighbors(g, pair);
    for (const k of g.members) office.gesture(k, k === speaker ? 'talk' : k === listener ? 'listen' : null);
    // 头顶冒这句话
    const index = g.queue.findIndex(m => m.from === speaker);
    const d = this.world.data;
    if (index >= 0) {
      const m = g.queue.splice(index, 1)[0];
      const to = d.sessions.get(m.to)?.title || '';
      const voice = this.world.voice;
      this.world.hud.bubble(speaker, { role: 'talk', to, text: m.text, ts: Date.now() }, { linger: voice.on ? 40 : BEAT * 2.2 });
      if (voice.on) {
        // 2 倍速念出来：念的时候他一直站着比划、头顶声波在跳，念完气泡收起、轮到下一句
        // 排队念：前面还有别人（别的一拨）在念时先等着，轮到了才开始比划、冒声波
        g.holding = true;
        voice.speak(speaker, m.text, { onStart: () => this.world.hud.speaking(speaker, true) }).then(() => {
          g.holding = false;
          g.beatAt = this.world.time - BEAT + 0.6;
          this.world.hud.speaking(speaker, false);
          setTimeout(() => this.world.hud.collapse(speaker), 1200);
        });
      }
    } else {
      this.world.hud.bubble(speaker, { role: 'dots', text: '', ts: Date.now() }, { linger: BEAT * 0.9 });
    }
  }

  /// 两头的人朝里；中间的人对着这一句里跟他说话的那个（没轮到他就保持上一句的朝向）
  faceNeighbors(g, pair) {
    const office = this.world.office;
    const order = g.order, n = order.length;
    const where = (k) => (g.spots.get(k) || office.aislePos(k));
    order.forEach((k, i) => {
      let target;
      if (pair && pair.includes(k)) target = pair[0] === k ? pair[1] : pair[0];
      else if (i === 0) target = order[1];
      else if (i === n - 1) target = order[n - 2];
      else if (g.facing?.get(k)) return;
      else target = order[i - 1];
      const a = where(k), b = where(target);
      if (!a || !b) return;
      office.face(k, yawToward(b.x - a.x, b.z - a.z));
      g.facing ??= new Map();
      g.facing.set(k, target);
    });
  }

  /// 对话框里的一行：A → B：摘要
  feed(link) {
    this.world.hud.chat.talk(link.from, link.to, link.summary, Date.now());
  }
}
