// 数据流大屏的演示数据：没有主程序时（浏览器直接打开 flow.html，或 ?demo）造十几个会话，
// 先补一段历史，再按真实节奏不停地读文件、改代码、跑测试、汇报。格式和 Kiteline 接口一样（state、entries）。

const PROJECTS = {
  'shop-app': ['src/pages/Home.tsx', 'src/pages/Cart.tsx', 'src/api/orders.ts', 'src/components/Price.tsx', 'server/routes/pay.py', 'server/models.py', 'tests/test_pay.py', 'README.md'],
  'content-studio': ['studio/render.py', 'studio/cover.py', 'studio/templates/post.html', 'models/loader.py', 'scripts/batch.sh', 'tests/test_render.py'],
  '官网': ['site/index.html', 'site/app.css', 'site/download.js', 'site/en/index.html', 'deploy.sh'],
  desktop: ['client/Views/Settings.cs', 'client/Views/Sidebar.cs', 'client/Model/AppModel.cs', 'host/server.py', 'host/delivery.py', 'tests/test_delivery.py'],
  'data-pipeline': ['etl/extract.py', 'etl/transform.py', 'etl/load.py', 'dags/daily.py', 'tests/test_transform.py', 'docs/schema.md'],
};
const SESSIONS = [
  ['shop-app', '会员资料编辑', 'busy', [2, 4, '开发中']], ['shop-app', '支付回调重试', 'busy', [3, 4, '测试中']], ['shop-app', '购物车价格精度', 'idle', null],
  ['content-studio', '封面图批量重出', 'busy', [1, 3, '摸清现状']], ['content-studio', '本地模型部署', 'waiting', [2, 5, '部署']],
  ['官网', '首屏视频轮播', 'busy', [4, 5, '验证']], ['官网', '下载页三平台', 'idle', null],
  ['desktop', 'Linux 投递修复', 'busy', [2, 4, '定位']], ['desktop', '设置页改版', 'busy', [3, 6, '开发中']], ['desktop', '自动更新', 'idle', null],
  ['data-pipeline', '日报数据延迟', 'busy', [2, 3, '修复']], ['data-pipeline', '字段改名迁移', 'idle', null], ['shop-app', '订单导出', 'busy', [1, 4, '读代码']],
];
const CODE = [
  'const total = items.reduce((a, b) => a + b.price * b.qty, 0);', 'if (!order.paid) return retry(order, attempt + 1);', 'await db.orders.update({ id, status: "paid" });',
  'def render_cover(post, size=(1200, 630)):', '    img = Image.new("RGB", size, "#0b0c0f")', 'export function formatPrice(cents: number) {', '  return (cents / 100).toFixed(2);',
  'public bool AutoUpdate { get; set; } = true;', 'df = df.rename(columns={"uid": "user_id"})', 'logger.info("loaded %d rows", len(rows))', '<video autoplay muted loop playsinline>',
];
const CMDS = [
  ['npm test -- --run src/api', 'test', ['Tests  42 passed (42)', 'Duration  3.21s']], ['pytest tests/test_pay.py -q', 'test', ['12 passed in 1.84s']],
  ['pytest tests/test_render.py -q', 'test', ['1 failed, 9 passed', 'FAILED tests/test_render.py::test_cover_size']], ['npm run build', 'build', ['✓ built in 4.12s']],
  ['dotnet build -c Release', 'build', ['Build succeeded.', '    0 Warning(s)']], ['git commit -am "fix: price rounding"', 'git', ['[main 3f2a1c9] fix: price rounding']],
  ['git push origin main', 'git', ['To github.com:acme/shop-app.git']], ['ssh gpu-server "nvidia-smi --query-gpu=memory.used --format=csv"', 'ssh', ['memory.used [MiB]', '7012 MiB']],
  ['python3 ~/.ccpulse/ccpulse-watch.py shot http://localhost:5173 --caption "改完的首页"', 'report', ['已发送 1 张图片到用户手机']],
  ['python3 ~/.ccpulse/ccpulse-watch.py stage 3 --note "跑测试"', 'report', ['已报告任务阶段：3/4 测试中']], ['ls -la src/pages', 'run', ['Home.tsx', 'Cart.tsx', 'Orders.tsx']],
  ['grep -rn "retry" server/', 'run', ['server/routes/pay.py:41: def retry(order, attempt):']],
];
const USER = ['价格显示有时候多一分钱，查一下', '封面图字太小了，放大一点', '下载页 Windows 的按钮点了没反应', '日报今天又晚了半小时，看看卡在哪', '可以，就按这个方案改'];

const pick = (a) => a[Math.floor(Math.random() * a.length)];
let nid = 1;

export function startDemo(flow) {
  const now = Date.now();
  // ?many=40：会话多到一列放不下（测「其余 N 个会话」）
  const many = +(new URLSearchParams(location.search).get('many') || 0);
  const list = SESSIONS.slice();
  for (let i = list.length; i < many; i++) list.push([Object.keys(PROJECTS)[i % 5], `演示会话 ${i + 1}`, i % 3 ? 'idle' : 'busy', null]);
  const sessions = list.map(([proj, title, activity, stage], i) => ({
    key: `demo-${i}`, title, cwd: `/home/dev/${proj}`, agent: i % 5 === 3 ? 'codex' : 'claude-code', sourceName: i % 3 ? 'Mac Studio' : 'gpu-server',
    activity, stage: stage ? { step: stage[0], total: stage[1], label: stage[2] } : null,
    usage: { context: 40000 + Math.round(Math.random() * 300000), window: 1000000, cacheRead: 30000 + Math.round(Math.random() * 200000), input: 4, output: 800, model: 'claude-opus-5-5' },
    updatedAt: now - i * 60000,
  }));
  flow.receive({ type: 'init', lang: 'zh', strings: {}, quality: 'high', door: false });
  flow.receive({ type: 'state', state: { sessions } });
  flow.receive({ type: 'usage', totals: { input: 120000, output: 486000, cacheRead: 52000000, cacheWrite: 2100000, requests: 1873, cost: 41.2 } });
  // 先补一段历史（不放动画）
  let ts = now - 3600 * 1000;
  for (let n = 0; n < 520; n++) {
    const s = pick(sessions);
    ts += 5000 + Math.random() * 4000;
    flow.onEntries(s.key, call(s, ts), false);
  }
  // 再按节奏来新的：忙的会话 1～4 秒一次
  const tick = () => {
    const busy = sessions.filter(s => s.activity !== 'idle');
    const s = Math.random() < .9 ? pick(busy) : pick(sessions);
    flow.receive({ type: 'entries', key: s.key, items: call(s, Date.now()) });
    setTimeout(tick, (250 + Math.random() * 700) / Math.max(1, busy.length / 6));
  };
  setTimeout(tick, 600);
  // 过一会儿来一个新会话（看新会话加入时卡片亮起来）
  setTimeout(() => {
    sessions.unshift({ key: 'demo-new', title: '新会话：数据看板', cwd: '/home/dev/data-pipeline', agent: 'claude-code', sourceName: 'Mac Studio', activity: 'busy',
      stage: { step: 1, total: 3, label: '摸清现状' }, usage: { context: 30000, window: 1000000, cacheRead: 20000, input: 4, output: 300, model: 'claude-opus-5-5' }, startedAt: Date.now() });
    flow.receive({ type: 'state', state: { sessions } });
  }, 7000);
  // 时不时有会话开工、歇下、推进一步
  setInterval(() => {
    const s = pick(sessions);
    if (Math.random() < .5) s.activity = s.activity === 'idle' ? 'busy' : Math.random() < .3 ? 'idle' : s.activity;
    if (s.stage && Math.random() < .5) s.stage.step = s.stage.step % s.stage.total + 1;
    s.usage.context += Math.round(Math.random() * 8000);
    s.updatedAt = Date.now();
    flow.receive({ type: 'state', state: { sessions } });
  }, 4000);
}

function call(s, ts) {
  const proj = s.cwd.split('/').pop(), files = PROJECTS[proj] || PROJECTS['shop-app'], file = `${s.cwd}/${pick(files)}`;
  const id = `t${nid++}`, items = [];
  const r = Math.random();
  if (r < .06) return [{ id: id + 'u', ts, t: 'user', text: pick(USER) }];
  if (Math.random() < .35) items.push({ id: id + 'th', ts: ts - 3000, t: 'thinking', text: '' });
  let tool, input, out = 'ok', err = false;
  if (r < .34) { tool = 'Read'; input = { file_path: file }; out = pick(CODE) + '\n'.repeat(40); }
  else if (r < .44) { tool = 'Grep'; input = { pattern: pick(['retry', 'price', 'render', 'AutoUpdate', 'user_id']), path: s.cwd }; out = file + ':12: …'; }
  else if (r < .58) { tool = 'Edit'; input = { file_path: file, old_string: pick(CODE), new_string: [pick(CODE), pick(CODE)].join('\n') }; out = 'The file has been updated.'; }
  else if (r < .62) { tool = 'Write'; input = { file_path: file.replace(/\.(\w+)$/, '.new.$1'), content: [pick(CODE), pick(CODE), pick(CODE)].join('\n') }; out = 'File created'; }
  else if (r < .66) { tool = Math.random() < .5 ? 'WebFetch' : 'WebSearch'; input = tool === 'WebFetch' ? { url: pick(['https://developer.apple.com/documentation/avfoundation', 'https://docs.python.org/3/library/asyncio.html', 'https://learn.microsoft.com/dotnet/api']) } : { query: pick(['WebView2 postMessage size limit', 'pytest flaky retry', 'ffmpeg loop video']) }; out = '…'; }
  else if (r < .69) { tool = 'SendMessage'; input = { to: 'demo-3', message: '我这边改完了，你那边可以接着跑测试', summary: '改完了，接着测' }; }
  else if (r < .7) { tool = 'Task'; input = { description: '核对三个平台的下载链接', prompt: '…' }; }
  else { const [cmd, , o] = pick(CMDS); tool = 'Bash'; input = { command: `cd ${s.cwd} && ${cmd}` }; out = o.join('\n'); err = /failed/.test(out); }
  items.push({ id, ts, t: 'tool', toolId: id, name: tool, input, model: 'claude-opus-5-5' });
  items.push({ id: id + 'r', ts: ts + 900, t: 'result', toolId: id, text: out, isError: err && Math.random() < .3 });
  return items;
}
