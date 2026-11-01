// 直连模式：网页从 Kiteline 服务自己的 /world/ 打开（Windows / Linux 客户端、浏览器），地址带着令牌 ?t=。
// 没有原生宿主把数据转进来，网页自己连接口：GET /api/state、实时事件 /api/events、/api/todos、/api/usage，
// 图片、头像带 ?t= 取，私聊 POST /api/send，朗读 POST /api/tts（电脑合成，2 倍速播）。
// 点屏幕、点卫星、离开这些动作照旧交给宿主（WebView2 的 chrome.webview）；没有宿主（浏览器里）就在页面里提示。

import { setStrings, t } from './i18n.js';

export async function startApi(world, params) {
  const token = params.get('t') || '';
  const base = (params.get('api') || location.origin).replace(/\/$/, '');
  const url = (path) => `${base}${path}${path.includes('?') ? '&' : '?'}t=${encodeURIComponent(token)}`;
  const headers = { 'X-CCP-Token': token, 'Content-Type': 'application/json' };
  const getJSON = async (path) => {
    const r = await fetch(url(path), { headers: { 'X-CCP-Token': token } });
    if (!r.ok) throw new Error(path + ' ' + r.status);
    return r.json();
  };

  // 动作交回客户端：WebView2 里走 postMessage；浏览器窗口里（Linux）POST 给后台，客户端从实时事件 world_intent 收
  const native = window.chrome?.webview;
  world.host.connected = true;
  world.host.post = (msg) => {
    if (msg.type === 'send') { world.api.send(msg.key, msg.text, msg.images || []); return; }
    if (msg.type === 'dictate') {
      world.receive({ type: 'dictation', state: 'failed', text: navigator.userAgent.includes('Windows') ? t('这里暂不支持听写，可以按 Win+H 用系统听写') : t('这里暂不支持听写') });
      return;
    }
    if (!['open', 'machine', 'exit'].includes(msg.type)) return;
    if (native) native.postMessage(msg);
    else fetch(base + '/api/world/intent', { method: 'POST', headers, body: JSON.stringify(msg) }).catch(() => {});
  };

  // 图片、头像都要带令牌
  world.mediaBase = base + '/';
  world.mediaSuffix = '&t=' + encodeURIComponent(token);
  world.api = {
    async send(key, text, images) {
      try {
        const r = await fetch(base + '/api/send', { method: 'POST', headers, body: JSON.stringify({ key, text, images: images.map((data, i) => ({ name: `image-${i + 1}.png`, data })), cid: Date.now().toString(36) }) });
        world.receive({ type: 'sent', ok: r.ok });
      } catch { world.receive({ type: 'sent', ok: false }); }
    },
    /// 朗读：电脑合成的音频（mp3 / wav），合成不了就退回浏览器自带语音
    async tts(text, voice) {
      const r = await fetch(base + '/api/tts', { method: 'POST', headers, body: JSON.stringify({ text, voice: voice || undefined, rate: 1 }) });
      if (!r.ok) throw new Error('tts ' + r.status);
      return URL.createObjectURL(await r.blob());
    },
  };

  const lang = params.get('lang') || ((navigator.language || 'zh').toLowerCase().startsWith('zh') ? 'zh' : 'en');
  let strings = {};
  if (lang === 'en') { try { strings = await (await fetch('en.json')).json(); } catch { /* 没有英文表就显示中文 */ } }
  let voices = [];
  try { voices = ((await getJSON('/api/tts/voices')).voices || []).map(v => v.id || v).filter(Boolean).slice(0, 6); } catch { /* 电脑没有语音合成 */ }
  // 没有原生工具栏（浏览器窗口）时右上角给一扇门；WebView2 里客户端自己有门
  world.receive({ type: 'init', lang, strings, brand: params.get('brand') || '#D97757', quality: 'high', door: !native || params.has('door'), voices });
  setStrings(lang, strings);

  const refresh = async () => {
    try { world.receive({ type: 'state', state: await getJSON('/api/state') }); } catch (e) { console.warn(e); }
  };
  await refresh();
  try { world.receive({ type: 'todos', ...(await getJSON('/api/todos')), initial: true }); } catch { /* 老版本没有待办 */ }
  const usage = async () => { try { world.receive({ type: 'usage', ...(await getJSON('/api/usage?days=1')) }); } catch { /* 没有用量 */ } };
  usage();
  setInterval(usage, 60000);

  // 实时事件（断了浏览器自己重连；重连后再取一次整份）
  const events = new EventSource(url('/api/events'));
  const on = (name, fn) => events.addEventListener(name, (e) => { try { fn(JSON.parse(e.data)); } catch { /* 格式不对的跳过 */ } });
  on('state', (state) => world.receive({ type: 'state', state }));
  on('entries', (body) => world.receive({ type: 'entries', ...body }));
  on('peers', (body) => world.receive({ type: 'peers', ...body }));
  on('sys', (body) => world.receive({ type: 'sys', ...body }));
  on('todos', (body) => world.receive({ type: 'todos', ...body }));
  let lost = false;
  events.onerror = () => { lost = true; };
  events.onopen = () => { if (lost) { lost = false; refresh(); } };

  // 看不见（窗口最小化、切到别的标签）就停画；回来接着画
  document.addEventListener('visibilitychange', () => world.receive({ type: 'active', active: !document.hidden, visible: !document.hidden }));
}
