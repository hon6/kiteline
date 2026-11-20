// AR 模式的演示数据：没有主程序时（浏览器直接打开 ar.html，或 ?demo）造十几个会话，带对话、阶段、等确认、浏览器画面，
// 之后按节奏冒新消息（看抖动、边缘方向标、跟随）。格式同 Kiteline 接口（state、entries、browser_frame）。

const PROJECTS = ['shop-app', 'content-studio', '官网', 'desktop', 'data-pipeline'];
const SESSIONS = [
  ['shop-app', '会员资料编辑', 'busy', [2, 4, '开发中'], '正在运行 npm test -- src/api'],
  ['shop-app', '支付回调重试', 'waiting', [3, 4, '测试中'], null],
  ['shop-app', '购物车价格精度', 'idle', null, null],
  ['content-studio', '封面图批量重出', 'busy', [1, 3, '摸清现状'], '正在读取 studio/cover.py'],
  ['content-studio', '本地模型部署', 'idle', [2, 5, '部署'], null],
  ['官网', '首屏视频轮播', 'busy', [4, 5, '验证'], '正在截图首页'],
  ['官网', '下载页三平台', 'idle', null, null],
  ['desktop', 'Linux 投递修复', 'busy', [2, 4, '定位'], '正在搜索 delivery.py'],
  ['desktop', '设置页改版', 'busy', [3, 6, '开发中'], '正在编辑 Settings.cs'],
  ['desktop', '自动更新', 'idle', null, null],
  ['data-pipeline', '日报数据延迟', 'busy', [2, 3, '修复'], '正在运行 pytest'],
  ['data-pipeline', '字段改名迁移', 'idle', null, null],
];
const REPLIES = [
  '改好了。价格统一按「分」存整数，显示时再除以 100：\n\n```ts\nexport function formatPrice(cents: number) {\n  return (cents / 100).toFixed(2);\n}\n```\n\n- 购物车合计不再出现多一分钱\n- 加了 6 个边界用例，全部通过',
  '定位到原因了：**回调重试**在网络抖动时会重复入账。\n\n1. 用订单号做幂等键\n2. 重试间隔改成指数退避（1s、2s、4s）\n3. 超过 5 次转人工\n\n要我直接改吗？',
  '首页轮播已经换成新视频，三种屏幕宽度都截了图发到你手机上。移动端首帧加载从 2.8 秒降到 1.1 秒。',
  '| 平台 | 状态 | 大小 |\n|---|---|---|\n| macOS | 已上传 | 18.2 MB |\n| Windows | 已上传 | 21.7 MB |\n| Linux | 构建中 | — |',
  '日报延迟是因为 `transform` 这一步每次全量重算。改成只算增量后，昨天的数据 3 分钟就跑完了（原来 34 分钟）。',
  '设置页按新的设计拆成了四组：通用、外观、通知、高级。所有开关都保留了原来的默认值，旧配置能直接读。',
];
const USER = ['价格显示有时候多一分钱，查一下', '支付回调好像会重复入账', '首屏换成新视频', '下载页 Windows 的按钮点了没反应', '日报今天又晚了半小时，看看卡在哪', '可以，就按这个方案改', '设置页按新设计改一下'];
const TOOLS = [['Bash', 'npm test -- --run src/api'], ['Read', 'src/pages/Cart.tsx'], ['Edit', 'src/components/Price.tsx'], ['Grep', 'retry server/'], ['Bash', 'pytest tests/test_pay.py -q'], ['WebFetch', 'developer.apple.com'], ['Bash', 'git commit -am "fix: price rounding"']];
const pick = (a) => a[Math.floor(Math.random() * a.length)];
let nid = 1;

export function startDemo(ar) {
  const now = Date.now();
  const sessions = SESSIONS.map(([proj, title, activity, stage, act], i) => ({
    key: `demo-${i}`, title, cwd: `/home/dev/${proj}`, agent: i % 5 === 3 ? 'codex' : 'claude-code', sourceName: i % 3 ? 'Mac Studio' : 'gpu-server',
    activity, activityText: act, stage: stage ? { step: stage[0], total: stage[1], label: stage[2] } : null,
    startedAt: now - (40 - i) * 600000, updatedAt: now - (i % 4) * 400000, viewedAt: i % 3 === 2 ? now : now - 3600000, canReply: true,
    ...(activity === 'waiting' ? { blocking: '要运行 git push origin main', pendingOptions: [{ key: '1', label: '允许', style: 'default' }, { key: '2', label: '总是允许' }, { key: 'esc', label: '拒绝', style: 'destructive' }] } : {}),
    ...(i === 5 || i === 0 ? { browser: { url: i === 5 ? 'http://localhost:5173/' : 'https://shop.example.com/cart', title: i === 5 ? '首页 · 官网' : '购物车', since: now - 300000 } } : {}),
  }));
  ar.receive({ type: 'init', lang: 'zh', strings: {}, brand: '#D97757', door: true, prefs: { layout: 'arc' } });
  ar.receive({ type: 'state', state: { sessions } });
  // 每个会话一段对话
  sessions.forEach((s, i) => {
    const items = [];
    let ts = now - 1800000;
    items.push({ id: `u${nid++}`, t: 'user', text: USER[i % USER.length], ts: ts += 60000 });
    for (let n = 0; n < 3 + (i % 3); n++) { const [name, brief] = pick(TOOLS); items.push({ id: `t${nid++}`, t: 'tool', name, brief, ts: ts += 20000 }); }
    items.push({ id: `a${nid++}`, t: 'text', text: REPLIES[i % REPLIES.length], ts: ts += 30000 });
    if (i % 2) { items.push({ id: `u${nid++}`, t: 'user', text: pick(USER), ts: ts += 60000 }); for (let n = 0; n < 2; n++) { const [name, brief] = pick(TOOLS); items.push({ id: `t${nid++}`, t: 'tool', name, brief, ts: ts += 15000 }); } }
    const p = ar.panels.get(s.key);
    if (p) { p.loaded = true; p.addItems(items); p.setSession(s); }
  });
  ar.stats();
  // 浏览器画面：画一张假的网页
  const frame = (key, title, hue) => {
    const c = document.createElement('canvas'); c.width = 960; c.height = 600;
    const g = c.getContext('2d');
    g.fillStyle = '#f6f6f4'; g.fillRect(0, 0, 960, 600);
    g.fillStyle = `hsl(${hue},40%,22%)`; g.fillRect(0, 0, 960, 64);
    g.fillStyle = '#fff'; g.font = '600 22px -apple-system, PingFang SC'; g.fillText(title, 32, 40);
    g.fillStyle = `hsl(${hue},55%,62%)`; g.fillRect(32, 100, 560, 300);
    g.fillStyle = '#222'; g.font = '700 34px -apple-system, PingFang SC'; g.fillText(title, 620, 160);
    g.fillStyle = '#666'; g.font = '18px -apple-system, PingFang SC';
    ['更快的加载速度', '三种屏幕宽度自适应', '支持深色模式'].forEach((s, i) => g.fillText('· ' + s, 620, 210 + i * 34));
    for (let i = 0; i < 3; i++) { g.fillStyle = '#e4e4e0'; g.fillRect(32 + i * 312, 430, 288, 140); }
    ar.receive({ type: 'browser_frame', key, seq: nid++, data: c.toDataURL('image/jpeg', 0.82).split(',')[1], url: '', title });
  };
  frame('demo-5', '首屏视频轮播', 18);
  frame('demo-0', '购物车', 210);
  // 之后时不时来新消息、换状态
  setInterval(() => {
    const s = pick(sessions);
    const items = [];
    const ts = Date.now();
    if (Math.random() < 0.5) { const [name, brief] = pick(TOOLS); items.push({ id: `t${nid++}`, t: 'tool', name, brief, ts }); }
    else { items.push({ id: `a${nid++}`, t: 'text', text: pick(REPLIES), ts }); s.activity = 'idle'; s.updatedAt = ts; }
    ar.receive({ type: 'entries', key: s.key, items });
    ar.receive({ type: 'state', state: { sessions } });
  }, 7000);
}

/// 自测用：给某个会话挂一块假的浏览器窗口（宿主的测试实例里没有真浏览器）
export function fakeBrowser(ar, key, title = '首页 · 预览') {
  const s = ar.sessions.get(key);
  if (!s) return false;
  s.browser = { url: 'http://localhost:5173/', title, since: Date.now() };
  ar.onState({ sessions: [...ar.sessions.values()] });
  const c = document.createElement('canvas'); c.width = 960; c.height = 600;
  const g = c.getContext('2d');
  g.fillStyle = '#f6f6f4'; g.fillRect(0, 0, 960, 600);
  g.fillStyle = '#20242c'; g.fillRect(0, 0, 960, 64);
  g.fillStyle = '#fff'; g.font = '600 22px -apple-system, PingFang SC'; g.fillText(title, 32, 40);
  g.fillStyle = '#d9a184'; g.fillRect(32, 100, 560, 300);
  g.fillStyle = '#222'; g.font = '700 34px -apple-system, PingFang SC'; g.fillText('新首页', 620, 160);
  g.fillStyle = '#666'; g.font = '18px -apple-system, PingFang SC';
  ['卡片间距 16px', '圆角 12px', '三种屏幕宽度自适应'].forEach((t, i) => g.fillText('· ' + t, 620, 210 + i * 34));
  for (let i = 0; i < 3; i++) { g.fillStyle = '#e4e4e0'; g.fillRect(32 + i * 312, 430, 288, 140); }
  ar.receive({ type: 'browser_frame', key, seq: 1, data: c.toDataURL('image/jpeg', 0.85).split(',')[1], url: 'http://localhost:5173/', title });
  return true;
}
