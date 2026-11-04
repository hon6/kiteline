// 左下角的对话框（游戏里那种聊天窗）：一行一条「时间 名字：内容」，名字每人一个固定颜色；
// agent 之间说话写「A → B」，你发的写「你 → 某会话」，用工具是灰色的系统消息。
// 顶上几个分页筛选；新消息来了自动滚到底（你往上翻着看时不打扰，右下角提示有几条新的）。
// 私聊：点人物或记录里的名字，选中跟谁说（多一个「私聊」分页只看和他有关的），底下输入框打字、⌘V 粘贴截图、拖图进来、点麦克风说话；
// 回车发送（Shift+回车换行），发出去同会话页（主程序转给那个会话）。没选人时输入框不能用，提示先选。

import { t } from './i18n.js';
import { hashOf } from './office.js';

const NAME_COLORS = ['#FFD54F', '#4FC3F7', '#AED581', '#F48FB1', '#FFB74D', '#B39DDB', '#80CBC4', '#E6EE9C', '#FF8A65', '#90CAF9'];
const MAX = 300;
const MAX_IMAGES = 6;

function esc(text) {
  return String(text ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function plain(text) {
  return String(text || '').replace(/```[\s\S]*?```/g, ' ').replace(/[*_`#>]+/g, '').replace(/\[([^\]]+)\]\([^)]+\)/g, '$1').replace(/\s+/g, ' ').trim();
}

export class ChatBox {
  constructor(world, root) {
    this.world = world;
    this.filter = 'all';
    this.unseen = 0;
    this.target = null;
    this.images = [];   // {data(base64), url}
    this.node = document.createElement('div');
    this.node.className = 'chatbox';
    const tabs = [['all', t('全部')], ['talk', t('交谈')], ['reply', t('回复')], ['action', t('动作')]];
    this.node.innerHTML = `<div class="tabs">${tabs.map(([id, name]) => `<button data-filter="${id}" class="${id === 'all' ? 'on' : ''}">${esc(name)}</button>`).join('')}`
      + `<button data-filter="dm" class="dm" hidden></button></div>`
      + '<div class="lines"></div><button class="more" hidden></button>'
      + '<div class="attach" hidden></div>'
      + `<div class="input"><button class="who" title="${esc(t('取消私聊'))}"></button>`
      + `<textarea rows="1" placeholder="${esc(t('点击人物或记录里的名字，选择私聊对象'))}" disabled></textarea>`
      + `<button class="mic" title="${esc(t('听写：点击开始说话，再点一次转成文字'))}" disabled><i></i><i></i><i></i><i></i></button>`
      + `<button class="send" disabled>${esc(t('发送'))}</button></div>`;
    this.lines = this.node.querySelector('.lines');
    this.more = this.node.querySelector('.more');
    this.dmTab = this.node.querySelector('.tabs .dm');
    this.who = this.node.querySelector('.input .who');
    this.field = this.node.querySelector('textarea');
    this.mic = this.node.querySelector('.mic');
    this.sendButton = this.node.querySelector('.send');
    this.attachRow = this.node.querySelector('.attach');
    root.appendChild(this.node);

    this.node.querySelector('.tabs').addEventListener('click', (e) => {
      const b = e.target.closest('button');
      if (b) this.setFilter(b.dataset.filter);
    });
    this.lines.addEventListener('click', (e) => {
      const img = e.target.closest('.pics img');
      if (img) { this.world.hud.showImage(img.src); return; }
      const name = e.target.closest('[data-key]');
      if (name) { this.choose(name.dataset.key); this.world.focusSession(name.dataset.key); }
    });
    this.lines.addEventListener('scroll', () => { if (this.atBottom()) { this.unseen = 0; this.more.hidden = true; } });
    this.more.addEventListener('click', () => this.toBottom());
    this.who.addEventListener('click', () => this.choose(null));

    // 输入：Ctrl+回车（Mac 上 ⌘+回车也行）发送，单按回车换行（输入法打英文时的回车不会误发）；高度跟着行数长，最多 4 行
    this.field.addEventListener('keydown', (e) => {
      e.stopPropagation();
      if (e.key === 'Enter' && (e.ctrlKey || e.metaKey) && !e.isComposing) { e.preventDefault(); this.send(); }
      if (e.key === 'Escape') { this.field.blur(); }
    });
    this.field.addEventListener('keyup', (e) => e.stopPropagation());
    this.field.addEventListener('input', () => this.grow());
    this.field.addEventListener('paste', (e) => {
      const files = [...(e.clipboardData?.items || [])].filter(i => i.type.startsWith('image/')).map(i => i.getAsFile()).filter(Boolean);
      if (files.length) { e.preventDefault(); this.attach(files); }
    });
    this.node.addEventListener('dragover', (e) => { if (this.target) e.preventDefault(); });
    this.node.addEventListener('drop', (e) => {
      if (!this.target) return;
      e.preventDefault();
      this.attach([...(e.dataTransfer?.files || [])].filter(f => f.type.startsWith('image/')));
    });
    this.sendButton.addEventListener('click', () => this.send());
    this.mic.addEventListener('click', () => this.dictate());
    this.render();
  }

  // MARK: 记录

  atBottom() { return this.lines.scrollHeight - this.lines.scrollTop - this.lines.clientHeight < 24; }

  toBottom() {
    this.lines.scrollTop = this.lines.scrollHeight;
    this.unseen = 0;
    this.more.hidden = true;
  }

  setFilter(filter) {
    if (filter === 'dm' && !this.target) filter = 'all';
    this.filter = filter;
    for (const x of this.node.querySelectorAll('.tabs button')) x.classList.toggle('on', x.dataset.filter === filter);
    for (const line of this.lines.children) this.applyFilter(line);
    this.toBottom();
  }

  applyFilter(line) {
    const f = this.filter;
    const show = f === 'all' || (f === 'dm' ? (line.dataset.keys || '').split(' ').includes(this.target) : line.classList.contains(f));
    line.hidden = !show;
  }

  name(key) {
    const s = this.world.data.sessions.get(key);
    const title = s?.title || '';
    const color = NAME_COLORS[Math.floor(hashOf(key) * 7717) % NAME_COLORS.length];
    return `<b data-key="${esc(key)}" style="color:${color}">${esc(title.length > 14 ? title.slice(0, 14) + '…' : title)}</b>`;
  }

  /// kind：talk（agent 之间）/ reply（agent 回复）/ user（你发的）/ action（用工具）
  add(kind, keys, html, ts) {
    const stick = this.atBottom();
    const line = document.createElement('div');
    line.className = 'line ' + kind;
    line.dataset.keys = keys.join(' ');
    const time = new Date(ts || Date.now());
    line.innerHTML = `<span class="time">${String(time.getHours()).padStart(2, '0')}:${String(time.getMinutes()).padStart(2, '0')}</span>${html}`;
    this.applyFilter(line);
    this.lines.appendChild(line);
    while (this.lines.children.length > MAX) this.lines.firstChild.remove();
    if (stick) this.toBottom();
    else if (!line.hidden) {
      this.unseen++;
      this.more.hidden = false;
      this.more.textContent = t('%@ 条新消息 ↓', this.unseen);
    }
  }

  reply(key, text, ts, images) {
    const body = plain(text);
    if (!body && !images?.length) return;
    this.add('reply', [key], `${this.name(key)}<span class="sep">：</span><span class="text">${esc(body.slice(0, 240))}</span>${this.thumbs(key, images)}`, ts);
  }

  /// 消息里的图：一排小图（像素边框），点了看大图
  thumbs(key, images) {
    if (!images?.length) return '';
    return `<span class="pics">${images.slice(0, 4).map(img => `<img src="${esc(this.world.mediaURL(key, img))}" alt="" loading="lazy">`).join('')}</span>`;
  }

  /// 你说的话：在这里发的先显示（灰一点），回显来了再变正常；同一句（别处发的、排队后又回显一次）不重复记
  user(key, text, ts, local = false, images = []) {
    const body = plain(text) || (images.length ? t('[图片]') : '');
    if (!body) return;
    this.mine ??= new Map();
    const seen = this.mine.get(key);
    if (seen && seen.body === body && Date.now() - seen.at < 30 * 60 * 1000) {
      if (!local) seen.line?.classList.remove('pending');
      return;
    }
    const pics = local ? (images.length ? `<span class="pics">${images.map(i => `<img src="${i.url}" alt="">`).join('')}</span>` : '') : this.thumbs(key, images);
    this.add('reply user' + (local ? ' pending' : ''), [key], `<b class="you">${esc(t('你'))}</b><span class="sep"> → </span>${this.name(key)}<span class="sep">：</span><span class="text">${esc(body.slice(0, 240))}</span>${pics}`, ts);
    this.mine.set(key, { body, at: Date.now(), line: this.lines.lastElementChild });
  }

  think(key, text, ts) {
    const body = plain(text);
    if (body) this.add('reply think', [key], `${this.name(key)}<span class="sep"> ${esc(t('在想'))}：</span><span class="text">${esc(body.slice(0, 240))}</span>`, ts);
  }

  talk(from, to, text, ts) {
    this.add('talk', [from, to], `${this.name(from)}<span class="sep"> → </span>${this.name(to)}<span class="sep">：</span><span class="text">${esc(plain(text).slice(0, 240) || t('（消息）'))}</span>`, ts);
  }

  action(key, name, brief, ts) {
    this.add('action', [key], `<span class="text">* ${this.name(key)} ${esc(t('使用'))} <span class="tool">${esc(name)}</span>${brief ? ' ' + esc(plain(brief).slice(0, 80)) : ''}</span>`, ts);
  }

  note(text) {
    this.add('system', [], `<span class="text">${esc(text)}</span>`);
  }

  /// 刚打开：最近几个人的最后一句话先放进来
  seed() {
    const d = this.world.data;
    const recent = [...d.latest.entries()].filter(([k]) => d.sessions.has(k)).sort((a, b) => (a[1].ts || 0) - (b[1].ts || 0)).slice(-12);
    for (const [key, m] of recent) {
      if (m.role === 'user') this.user(key, m.text, m.ts); else this.reply(key, m.text, m.ts, m.images);
    }
    this.toBottom();
  }

  // MARK: 私聊

  /// 选中跟谁说（null = 取消）：多一个「私聊」分页、输入框能用了、光标进去
  choose(key) {
    const s = key ? this.world.data.sessions.get(key) : null;
    this.target = s ? key : null;
    this.world.chatTarget = this.target;
    this.render();
    if (this.target) {
      this.setFilter('dm');
      setTimeout(() => this.field.focus(), 0);
    } else if (this.filter === 'dm') this.setFilter('all');
  }

  /// 换了界面语言（主程序的 init 晚于构造到）：固定写进去的字重写一遍，提示文字由 render 现算
  relabel() {
    const names = { all: t('全部'), talk: t('交谈'), reply: t('回复'), action: t('动作') };
    for (const b of this.node.querySelectorAll('.tabs button[data-filter]')) if (names[b.dataset.filter]) b.textContent = names[b.dataset.filter];
    this.who.title = t('取消私聊');
    this.mic.title = t('听写：点击开始说话，再点一次转成文字');
    this.sendButton.textContent = t('发送');
    this.render();
  }

  render() {
    const s = this.target ? this.world.data.sessions.get(this.target) : null;
    const can = !!s && !s.readOnly;
    this.dmTab.hidden = !s;
    if (s) this.dmTab.innerHTML = `${esc(t('私聊'))} · ${this.name(this.target)}`;
    this.who.hidden = !s;
    if (s) this.who.innerHTML = `${esc(t('对'))} ${this.name(this.target)} <span class="x">×</span>`;
    this.field.disabled = !can;
    this.mic.disabled = !can;
    // 提示文字一行放得下：太长的会话名截短；回车、⌘V 的用法放在悬停提示里
    const short = s && s.title.length > 10 ? s.title.slice(0, 10) + '…' : s?.title;
    this.field.placeholder = !s ? t('点人物或名字，选择私聊对象') : can ? t('发消息给 %@', short) : t('这个会话只能看，不能回复');
    this.field.title = can ? t('Ctrl+回车发送（⌘+回车也行），回车换行，⌘V 粘贴截图') : '';
    this.sendButton.title = t('发送（Ctrl+回车）');
    this.updateSend();
  }

  updateSend() {
    this.sendButton.disabled = this.field.disabled || (!this.field.value.trim() && !this.images.length);
  }

  grow() {
    this.field.style.height = 'auto';
    this.field.style.height = Math.min(this.field.scrollHeight, 72) + 'px';
    this.updateSend();
  }

  attach(files) {
    for (const file of files.slice(0, MAX_IMAGES - this.images.length)) {
      const reader = new FileReader();
      reader.onload = () => {
        const url = String(reader.result);
        this.images.push({ url, data: url.slice(url.indexOf(',') + 1) });
        this.renderImages();
      };
      reader.readAsDataURL(file);
    }
  }

  renderImages() {
    this.attachRow.hidden = !this.images.length;
    this.attachRow.innerHTML = this.images.map((img, i) => `<span class="thumb"><img src="${img.url}" alt=""><button data-i="${i}">×</button></span>`).join('');
    for (const b of this.attachRow.querySelectorAll('button')) b.onclick = () => { this.images.splice(Number(b.dataset.i), 1); this.renderImages(); };
    this.updateSend();
  }

  send() {
    if (!this.target || this.field.disabled) return;
    const text = this.field.value.trim();
    if (!text && !this.images.length) return;
    if (this.world.host.connected) {
      this.world.host.post({ type: 'send', key: this.target, text, images: this.images.map(i => i.data) });
      this.user(this.target, text, Date.now(), true, this.images.slice());
    } else {
      // 演示：直接当成发出去了
      this.world.receive({ type: 'entries', key: this.target, items: [{ t: 'user', id: 'demo' + Date.now(), ts: Date.now(), text, images: this.images.map((i, k) => ({ ref: 'demo' + k, url: i.url })) }] });
    }
    this.field.value = '';
    this.images = [];
    this.renderImages();
    this.grow();
  }

  /// 发出去了没有（主程序回的）
  sent(ok) {
    if (!ok) this.note(t('发送失败，请稍后重试'));
  }

  // MARK: 听写

  dictate() {
    if (!this.target) return;
    if (!this.world.host.connected) { this.note(t('听写要在 Kiteline 里使用')); return; }
    const state = this.mic.dataset.state;
    if (state === 'recording') this.world.host.post({ type: 'dictate', action: 'stop' });
    else if (!state) { this.mic.dataset.state = 'starting'; this.world.host.post({ type: 'dictate', action: 'start' }); }
  }

  /// 主程序回的听写进度：recording / level / converting / done / failed
  dictation(msg) {
    const bars = this.mic.querySelectorAll('i');
    switch (msg.state) {
      case 'recording': this.mic.dataset.state = 'recording'; this.mic.title = t('说完点一下，转成文字'); break;
      case 'level': bars.forEach((b, i) => { b.style.height = (3 + Math.min(1, msg.level * (0.6 + i * 0.25)) * 11) + 'px'; }); break;
      case 'converting': this.mic.dataset.state = 'converting'; break;
      case 'done':
        delete this.mic.dataset.state;
        bars.forEach(b => { b.style.height = ''; });
        if (msg.text) {
          const sep = this.field.value && !/\s$/.test(this.field.value) && /[A-Za-z0-9]$/.test(this.field.value) && /^[A-Za-z0-9]/.test(msg.text) ? ' ' : '';
          this.field.value += sep + msg.text;
          this.grow();
          this.field.focus();
        } else if (msg.note) this.note(msg.note);
        break;
      case 'failed':
        delete this.mic.dataset.state;
        if (msg.text) this.note(msg.text);
        break;
    }
  }
}
