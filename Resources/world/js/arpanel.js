// AR 模式里漂在空中的窗口：每个会话一块（标题条 + 最近的对话 + 底栏），会话在用 Kiteline 的浏览器时旁边再挂一块浏览器画面。
// 窗口是真的网页元素（CSS3DObject），字是清晰的文字、能滚动、能选中；ar.js 管摆放、运镜和交互，这里只管内容。

import { CSS3DObject } from '../vendor/addons/renderers/CSS3DRenderer.js';
import { t } from './i18n.js';

export const PW = 520, PH = 420;          // 平时的窗口尺寸（CSS 像素 = 场景单位）
const REST_ITEMS = 26, FOCUS_ITEMS = 90;  // 平时 / 打开时最多画几条
const KEEP_ITEMS = 160;

export const esc = (s) => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
export const projectOf = (s) => {
  const cwd = String(s?.cwd || '').replace(/\/+$/, '');
  return cwd.split(/[\\/]/).pop() || t('未命名项目');
};

/// 一份很小的 Markdown：代码块、标题、列表、引用、表格行、粗体、行内代码、链接。够看清 agent 的回复，不求完整
export function markdown(text) {
  const out = [];
  const lines = String(text || '').replace(/\r/g, '').split('\n');
  let i = 0, list = null, para = [];
  const flushPara = () => { if (para.length) { out.push(`<p>${inline(para.join('\n'))}</p>`); para = []; } };
  const flushList = () => { if (list) { out.push(`<${list.tag}>${list.items.map(x => `<li>${inline(x)}</li>`).join('')}</${list.tag}>`); list = null; } };
  while (i < lines.length) {
    const line = lines[i];
    const fence = line.match(/^\s*```(\S*)/);
    if (fence) {
      flushPara(); flushList();
      const body = [];
      i++;
      while (i < lines.length && !/^\s*```/.test(lines[i])) body.push(lines[i++]);
      i++;
      out.push(`<pre><code>${esc(body.slice(0, 40).join('\n'))}${body.length > 40 ? '\n…' : ''}</code></pre>`);
      continue;
    }
    const head = line.match(/^(#{1,6})\s+(.*)$/);
    if (head) { flushPara(); flushList(); out.push(`<h4>${inline(head[2])}</h4>`); i++; continue; }
    const item = line.match(/^\s*(?:([-*+])|(\d+)[.)])\s+(.*)$/);
    if (item) {
      flushPara();
      const tag = item[2] ? 'ol' : 'ul';
      if (!list || list.tag !== tag) { flushList(); list = { tag, items: [] }; }
      list.items.push(item[3]);
      i++; continue;
    }
    if (/^\s*\|.*\|\s*$/.test(line)) {
      flushPara(); flushList();
      const rows = [];
      while (i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i])) {
        if (!/^\s*\|[\s:|-]+\|\s*$/.test(lines[i])) rows.push(lines[i].trim().slice(1, -1).split('|').map(c => c.trim()));
        i++;
      }
      out.push(`<table>${rows.slice(0, 14).map((r, n) => `<tr>${r.map(c => n ? `<td>${inline(c)}</td>` : `<th>${inline(c)}</th>`).join('')}</tr>`).join('')}</table>`);
      continue;
    }
    if (/^\s*>\s?/.test(line)) { flushPara(); flushList(); out.push(`<blockquote>${inline(line.replace(/^\s*>\s?/, ''))}</blockquote>`); i++; continue; }
    if (!line.trim()) { flushPara(); flushList(); i++; continue; }
    if (list && /^\s{2,}\S/.test(line)) { list.items[list.items.length - 1] += ' ' + line.trim(); i++; continue; }
    flushList();
    para.push(line);
    i++;
  }
  flushPara(); flushList();
  return out.join('');
}

function inline(text) {
  const codes = [];
  let s = String(text).replace(/`([^`\n]+)`/g, (_, c) => { codes.push(c); return `\u0000${codes.length - 1}\u0000`; });
  s = esc(s)
    .replace(/\*\*([^*]+)\*\*/g, '<b>$1</b>')
    .replace(/(^|[^*])\*([^*\n]+)\*(?!\*)/g, '$1<i>$2</i>')
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, '<u>$1</u>')
    .replace(/\n/g, '<br>');
  return s.replace(/\u0000(\d+)\u0000/g, (_, n) => `<code>${esc(codes[+n])}</code>`);
}

const ago = (ms) => {
  const s = Math.max(0, (Date.now() - ms) / 1000);
  if (s < 50) return t('刚刚');
  if (s < 3600) return t('%@ 分钟前', Math.round(s / 60));
  if (s < 86400) return t('%@ 小时前', Math.round(s / 3600));
  return t('%@ 天前', Math.round(s / 86400));
};

/// 会话的状态：busy 在工作 / waiting 等你确认 / error 出错 / idle 空闲
export function statusOf(s) {
  if (!s) return 'idle';
  if (s.activity === 'waiting') return 'waiting';
  if (s.activity === 'busy') return 'busy';
  if (s.error) return 'error';
  return 'idle';
}

class Base {
  constructor(ar, id, cls) {
    this.ar = ar; this.id = id;
    this.el = document.createElement('div');
    this.el.className = 'pn ' + cls;
    this.el.dataset.id = id;
    this.el.style.width = PW + 'px';
    this.el.style.height = PH + 'px';
    this.inner = document.createElement('div');
    this.inner.className = 'pn-in enter';
    this.el.appendChild(this.inner);
    this.obj = new CSS3DObject(this.el);
    this.obj.rotation.order = 'YXZ';
    this.rest = null;            // { pos, quat }：在墙上的位置
    this.w = PW; this.h = PH;
    this.attn = false;
    setTimeout(() => this.inner.classList.remove('enter'), 1400);
  }
  setSize(w, h) {
    if (w === this.w && h === this.h) return;
    this.w = w; this.h = h;
    this.el.style.width = w + 'px';
    this.el.style.height = h + 'px';
  }
  /// 有消息时隔一会儿抖一下（ar.js 按节奏叫）
  ping() {
    this.inner.classList.remove('ping');
    void this.inner.offsetWidth;
    this.inner.classList.add('ping');
  }
  dispose() { this.el.remove(); }
}

export class SessionPanel extends Base {
  constructor(ar, key) {
    super(ar, key, 'pn-s');
    this.key = key;
    this.items = new Map();   // id → 条目
    this.loaded = false;
    this.unread = false;
    this.session = null;
    this.inner.innerHTML = `
      <header class="pn-hd">
        <i class="pn-dot"></i>
        <span class="pn-mark"></span>
        <div class="pn-tt"><b></b><span></span></div>
        <em class="pn-stage"></em>
        <span class="pn-badge" data-w="${esc(t('待确认'))}">${esc(t('新消息'))}</span>
        <div class="pn-acts">
          <button class="pn-btn pn-open" title="${esc(t('在主窗口中打开'))}">${ICON.open}</button>
          <button class="pn-btn pn-close" title="${esc(t('返回（Esc）'))}">${ICON.close}</button>
        </div>
      </header>
      <div class="pn-body"><div class="pn-msgs"></div></div>
      <footer class="pn-ft"><span class="pn-act"></span><div class="pn-opts"></div></footer>
      <form class="pn-input${ar.touch ? ' voice' : ''}">
        <button type="button" class="pn-mode" title="${esc(t('切换语音 / 键盘'))}">${ar.touch ? ICON.keyboard : ICON.mic}</button>
        <textarea rows="1" placeholder=""></textarea>
        <button type="button" class="pn-talk">${esc(t('按住 说话'))}</button>
        <button type="submit" class="pn-send" title="${esc(t('发送（回车）'))}">${ICON.send}</button>
      </form>
      <div class="pn-chips"><span class="ch-model"></span><span class="ch-ctx"></span></div>`;
    this.$ = (sel) => this.inner.querySelector(sel);
    this.body = this.$('.pn-body');
    this.msgs = this.$('.pn-msgs');
    this.pinned = true;
    this.body.addEventListener('scroll', () => {
      this.pinned = this.body.scrollHeight - this.body.scrollTop - this.body.clientHeight < 40;
    }, { passive: true });
    this.$('.pn-open').addEventListener('click', (e) => { e.stopPropagation(); ar.post({ type: 'open', key }); });
    this.$('.pn-close').addEventListener('click', (e) => { e.stopPropagation(); ar.unpin(); });
    const form = this.$('.pn-input'), area = form.querySelector('textarea');
    // 点进输入框就能打字：窗口飘到眼前、放大、停住（不再飞到中间另开一个会话页）；宿主那边别再把字母当 WASD
    area.addEventListener('focus', () => { if (ar.pinned !== this) ar.pin(this); ar.post({ type: 'typing', on: true }); });
    area.addEventListener('blur', () => ar.post({ type: 'typing', on: false }));
    // 点图看大图
    this.msgs.addEventListener('click', (e) => {
      const img = e.target.closest('img');
      if (img) { e.stopPropagation(); ar.lightbox(img.src); }
    });
    const grow = () => { area.style.height = 'auto'; area.style.height = Math.min(140, area.scrollHeight) + 'px'; };
    area.addEventListener('input', grow);
    area.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.shiftKey && !e.isComposing && e.keyCode !== 229) { e.preventDefault(); form.requestSubmit(); }
    });
    // 手机、iPad 上默认「按住 说话」（11-22：现在没人打字了），左边按钮切到键盘；松开转成文字发给这个会话
    const mode = this.$('.pn-mode'), talk = this.$('.pn-talk');
    mode.addEventListener('click', (e) => {
      e.stopPropagation();
      const voice = !form.classList.contains('voice');
      form.classList.toggle('voice', voice);
      mode.innerHTML = voice ? ICON.keyboard : ICON.mic;
      if (!voice) area.focus({ preventScroll: true });
    });
    const down = (e) => {
      e.stopPropagation(); e.preventDefault();
      if (ar.pinned !== this) ar.pin(this);
      talk.setPointerCapture?.(e.pointerId);
      ar.talkStart(key, talk);
    };
    talk.addEventListener('pointerdown', down);
    talk.addEventListener('pointerup', (e) => { e.stopPropagation(); ar.talkStop(false); });
    talk.addEventListener('pointercancel', (e) => { e.stopPropagation(); ar.talkStop(true); });
    form.addEventListener('submit', (e) => {
      e.preventDefault();
      const text = area.value.trim();
      if (!text) return;
      ar.send(key, text);
      area.value = ''; grow();
    });
    this.$('.pn-opts').addEventListener('click', (e) => {
      const b = e.target.closest('button[data-k]');
      if (!b) return;
      e.stopPropagation();
      ar.post({ type: 'press', key, button: b.dataset.k, label: b.textContent });
      b.classList.add('sent');
    });
  }

  get input() { return this.$('.pn-input textarea'); }
  /// 输入栏在「按住 说话」（手机、iPad 默认）：打开窗口时别把光标放进输入框（会弹键盘）
  get voice() { return this.$('.pn-input').classList.contains('voice'); }

  setSession(s) {
    this.session = s;
    const st = statusOf(s);
    this.status = st;
    this.el.classList.toggle('busy', st === 'busy');
    this.el.classList.toggle('waiting', st === 'waiting');
    this.el.classList.toggle('error', st === 'error');
    this.el.classList.toggle('ro', !!s.readOnly || s.canReply === false);
    this.$('.pn-tt b').textContent = s.title || s.name || t('会话');
    const meta = [projectOf(s), s.sourceName, s.branch].filter(Boolean);
    this.$('.pn-tt span').textContent = meta.join(' · ');
    const stage = s.stage && s.stage.total ? `${s.stage.step}/${s.stage.total} ${s.stage.label || ''}`.trim() : '';
    this.$('.pn-stage').textContent = stage;
    this.$('.pn-stage').hidden = !stage;
    this.$('.pn-mark').innerHTML = this.ar.markSvg(s.agent);
    // 底栏：等你确认时写清楚在等什么、给出选项；在工作时是此刻在干什么；空闲时是最近一次活动
    let act;
    if (st === 'waiting') act = s.blocking || t('需要确认');
    else if (st === 'busy') act = s.activityText || (s.stage?.note) || t('正在工作…');
    else if (st === 'error') act = t('出错已停止：%@', s.error);
    else act = s.updatedAt ? t('空闲') + ' · ' + ago(s.updatedAt) : t('空闲');
    this.$('.pn-act').textContent = act;
    const opts = st === 'waiting' && Array.isArray(s.pendingOptions) ? s.pendingOptions : [];
    const sig = JSON.stringify(opts);
    if (sig !== this.optSig) {
      this.optSig = sig;
      this.$('.pn-opts').innerHTML = opts.slice(0, 4).map(o => `<button data-k="${esc(o.key)}" class="${o.style === 'destructive' ? 'no' : o.style === 'default' || o.style === 'primary' ? 'yes' : ''}">${esc(o.label)}</button>`).join('');
    }
    const agent = s.agent === 'codex' ? 'Codex' : s.agent && s.agent !== 'claude-code' ? s.agent : 'Claude';
    this.input.placeholder = this.el.classList.contains('ro') ? t('这个会话只能看，不能回复') : t('发消息给 %@', agent);
    // 输入框下面一排：模型、上下文用了多少（同会话页底下那排）
    const u = s.usage || {};
    const model = String(u.model || '').replace(/^claude-/, '').replace(/-(\d+)-(\d+)$/, ' $1.$2').replace(/^\w/, (c) => c.toUpperCase());
    this.$('.ch-model').textContent = model;
    this.$('.ch-model').hidden = !model;
    const ctx = u.context && u.window ? Math.round(u.context / u.window * 100) : null;
    this.$('.ch-ctx').textContent = ctx === null ? '' : ctx + '%';
    this.$('.ch-ctx').hidden = ctx === null;
    this.input.disabled = this.el.classList.contains('ro');
    // 新消息：最后一次有动静晚于最后一次看过（任何一端），且它停下来等你了（不是在工作中途、也不是别的会话来信引起的）
    const viewed = Math.max(s.viewedAt || 0, this.seenAt || 0);
    this.unread = st !== 'busy' && !s.fromPeer && !!s.updatedAt && s.updatedAt > viewed + 1500 && (this.loaded ? this.lastIsReply() : true);
    this.attn = st === 'waiting' || this.unread;
    this.el.classList.toggle('attn', this.attn);
  }

  lastIsReply() {
    const list = this.sorted();
    for (let i = list.length - 1; i >= 0; i--) {
      const it = list[i];
      if (it.t === 'text') return true;
      if (it.t === 'user') return false;
    }
    return true;
  }

  /// 看过了：本机先记下（不等宿主回推），宿主那边记「打开过」（各端的新消息提示一起消）
  seen() {
    this.seenAt = Date.now();
    if (this.unread) {
      this.unread = false;
      this.attn = this.status === 'waiting';
      this.el.classList.toggle('attn', this.attn);
      this.ar.post({ type: 'viewed', key: this.key });
    }
  }

  addItems(items) {
    let changed = false;
    for (const it of items || []) {
      if (!it || !it.t) continue;
      // 真的「你说的话」回来了：发送时先放的那条占位（虚线框）去掉，不然同一句显示两遍
      if (it.t === 'user' && !String(it.id || '').startsWith('local-')) {
        const text = String(it.text || '').trim();
        for (const [id, old] of this.items) if (id.startsWith('local-') && String(old.text || '').trim() === text) this.items.delete(id);
      }
      const id = it.id || `${it.t}:${it.ts}:${(it.text || '').slice(0, 20)}`;
      const was = this.items.get(id);
      this.items.set(id, was ? { ...was, ...it } : it);
      changed = true;
    }
    if (this.items.size > KEEP_ITEMS) {
      const drop = this.sorted().slice(0, this.items.size - KEEP_ITEMS);
      for (const it of drop) this.items.delete(it.id);
    }
    if (changed) this.render();
  }

  sorted() { return [...this.items.values()].sort((a, b) => (a.ts || 0) - (b.ts || 0)); }

  render() {
    const big = this.el.classList.contains('focus') || this.el.classList.contains('hover');
    const all = this.sorted().filter(it => it.t !== 'thinking' && it.t !== 'event' && !(it.t === 'result' && !(it.images || []).length)
      && !(it.t === 'text' && !String(it.text || '').trim() && !(it.images || []).length));
    const list = all.slice(-(big ? FOCUS_ITEMS : REST_ITEMS));
    const results = new Map();
    for (const it of this.items.values()) if (it.t === 'result' && it.toolId) results.set(it.toolId, it);
    const time = (ts) => { if (!ts) return ''; const d = new Date(ts); return `<time>${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}</time>`; };
    const html = [];
    let tools = [];
    const flushTools = () => {
      if (!tools.length) return;
      const shown = tools.slice(-4);
      html.push(`<div class="m t">${tools.length > 4 ? `<s>${esc(t('%@ 次调用', tools.length))}</s>` : ''}${shown.map(x =>
        `<div class="${x.err ? 'err' : 'ok'}"><i></i><b>${esc(x.name)}</b><span>${esc(x.brief)}</span><em>›</em></div>`).join('')}</div>${time(tools[tools.length - 1].ts)}`);
      tools = [];
    };
    for (const it of list) {
      if (it.t === 'tool') {
        const brief = String(it.brief || '').replace(new RegExp('^' + String(it.name || '').replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\s*[:：]\\s*'), '');
        tools.push({ name: it.name || t('工具'), brief: brief.slice(0, 140), ts: it.ts, err: results.get(it.toolId || it.id)?.isError });
        continue;
      }
      flushTools();
      const imgs = (it.images || []).filter(x => x && x.ref).slice(0, 4).map(x => `<img loading="lazy" src="${esc(this.ar.mediaUrl(this.key, x.ref))}">`).join('');
      if (it.t === 'user') html.push(`<div class="m u${it.queued ? ' q' : ''}"><div>${esc(String(it.text || '').slice(0, 1500))}${imgs ? `<p class="im">${imgs}</p>` : ''}</div></div>${time(it.ts).replace('<time>', '<time class="r">')}`);
      else if (it.t === 'text') html.push(`<div class="m a">${markdown(String(it.text || '').slice(0, big ? 12000 : 3000))}</div>${time(it.ts)}`);
      else if (imgs) html.push(`<div class="m a"><p class="im">${imgs}</p></div>${time(it.ts)}`);
    }
    flushTools();
    if (!html.length) html.push(`<div class="m e">${esc(this.loaded ? t('暂无消息') : t('正在载入…'))}</div>`);
    this.msgs.innerHTML = html.join('');
    if (this.pinned) this.body.scrollTop = this.body.scrollHeight;
  }
}

/// 会话的浏览器画面：像一个浏览器窗口（地址栏 + 画面），画面是电脑推过来的 JPEG（平时小图、打开时大图）
export class BrowserTile extends Base {
  constructor(ar, key) {
    super(ar, 'b:' + key, 'pn-b');
    this.key = key;
    this.inner.innerHTML = `
      <header class="pn-hd br-hd">
        <span class="br-lights"><i></i><i></i><i></i></span>
        <div class="br-url"><svg viewBox="0 0 16 16"><path d="M8 1.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13Zm0 1.2c.7 0 1.6 1.5 1.9 3.8H6.1C6.4 4.2 7.3 2.7 8 2.7Zm-2 .5a8 8 0 0 0-1.1 3.3H2.8A5.3 5.3 0 0 1 6 3.2Zm4 0a5.3 5.3 0 0 1 3.2 3.3h-2.1A8 8 0 0 0 10 3.2ZM2.8 9.5h2.1A8 8 0 0 0 6 12.8a5.3 5.3 0 0 1-3.2-3.3Zm3.3 0h3.8c-.3 2.3-1.2 3.8-1.9 3.8s-1.6-1.5-1.9-3.8Zm5 0h2.1a5.3 5.3 0 0 1-3.2 3.3 8 8 0 0 0 1.1-3.3ZM6 7.7h4v.6H6z" fill="currentColor"/></svg><span></span></div>
        <div class="pn-acts"><button class="pn-btn pn-close" title="${esc(t('返回（Esc）'))}">${ICON.close}</button></div>
      </header>
      <div class="br-view"><img alt=""><p>${esc(t('正在连接浏览器画面…'))}</p></div>
      <footer class="pn-ft"><span class="pn-act"></span></footer>`;
    this.img = this.inner.querySelector('.br-view img');
    this.wait = this.inner.querySelector('.br-view p');
    this.seq = -1;
    this.inner.querySelector('.pn-close').addEventListener('click', (e) => { e.stopPropagation(); ar.unfocus(); });
  }
  setSession(s) {
    this.session = s;
    const b = s.browser || {};
    let host = b.url || '';
    try { host = new URL(b.url).host || b.url; } catch { /* 不是网址就原样显示 */ }
    this.inner.querySelector('.br-url span').textContent = host || t('浏览器');
    this.inner.querySelector('.pn-act').textContent = (b.title ? b.title + ' · ' : '') + (s.title || '');
    this.attn = !!b.ask;
    this.el.classList.toggle('attn', this.attn);
    this.status = b.ask ? 'waiting' : statusOf(s);
  }
  frame(msg) {
    if (typeof msg.seq === 'number' && msg.seq <= this.seq && this.seq - msg.seq < 1000) return;
    this.seq = msg.seq ?? this.seq;
    if (!msg.data) return;
    this.img.src = 'data:image/jpeg;base64,' + msg.data;
    this.wait.hidden = true;
    this.el.classList.add('live');
    if (msg.url) {
      let host = msg.url;
      try { host = new URL(msg.url).host || msg.url; } catch { /* 原样 */ }
      this.inner.querySelector('.br-url span').textContent = host;
    }
  }
}

/// 项目名牌：浮在这一组窗口上方
export class GroupLabel {
  constructor(name) {
    this.el = document.createElement('div');
    this.el.className = 'ar-group';
    this.el.innerHTML = `<b></b><span></span>`;
    this.obj = new CSS3DObject(this.el);
    this.obj.rotation.order = 'YXZ';
    this.set(name, 0, 0);
  }
  set(name, count, busy) {
    this.el.querySelector('b').textContent = name;
    this.el.querySelector('span').textContent = busy ? t('%@ 个会话 · %@ 个在工作', count, busy) : t('%@ 个会话', count);
  }
}

export const ICON = {
  open: '<svg viewBox="0 0 16 16"><path d="M9 2.5h4.5V7M13.3 2.7 7.5 8.5M12 9.5v3a1 1 0 0 1-1 1H3.5a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1h3" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  close: '<svg viewBox="0 0 16 16"><path d="M4 4l8 8M12 4l-8 8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>',
  send: '<svg viewBox="0 0 16 16"><path d="M8 13V3.5M3.8 7.6 8 3.4l4.2 4.2" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  mic: '<svg viewBox="0 0 16 16"><rect x="5.5" y="1.8" width="5" height="8" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M3.3 7.6a4.7 4.7 0 0 0 9.4 0M8 12.4v2" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>',
  keyboard: '<svg viewBox="0 0 16 16"><rect x="1.5" y="3.5" width="13" height="9" rx="2" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M4 6.5h.01M6.7 6.5h.01M9.3 6.5h.01M12 6.5h.01M4.8 9.6h6.4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>',
};
