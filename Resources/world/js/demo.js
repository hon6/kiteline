// 演示：没有主程序时（浏览器直接打开）造一份像样的数据，定时冒消息、换状态、发图、会话之间传信。
// 自测截图、调画面都用它；?shot 时不放随机事件，画面固定。

const MARKS = {
  'claude-code': [{ d: 'M20.998 10.949H24v3.102h-3v3.028h-1.487V20H18v-2.921h-1.487V20H15v-2.921H9V20H7.488v-2.921H6V20H4.487v-2.921H3V14.05H0V10.95h3V5h17.998v5.949zM6 10.949h1.488V8.102H6v2.847zm10.51 0H18V8.102h-1.49v2.847z' }],
  opencode: [{ d: 'M16 6H8v12h8V6zm4 16H4V2h16v20z' }],
  codex: [{ d: 'M8.086.457a6.105 6.105 0 013.046-.415c1.333.153 2.521.72 3.564 1.7a.117.117 0 00.107.029c1.408-.346 2.762-.224 4.061.366l.063.03.154.076c1.357.703 2.33 1.77 2.918 3.198.278.679.418 1.388.421 2.126a5.655 5.655 0 01-.18 1.631.167.167 0 00.04.155 5.982 5.982 0 011.578 2.891c.385 1.901-.01 3.615-1.183 5.14l-.182.22a6.063 6.063 0 01-2.934 1.851.162.162 0 00-.108.102c-.255.736-.511 1.364-.987 1.992-1.199 1.582-2.962 2.462-4.948 2.451-1.583-.008-2.986-.587-4.21-1.736a.145.145 0 00-.14-.032c-.518.167-1.04.191-1.604.185a5.924 5.924 0 01-2.595-.622 6.058 6.058 0 01-2.146-1.781c-.203-.269-.404-.522-.551-.821a7.74 7.74 0 01-.495-1.283 6.11 6.11 0 01-.017-3.064.166.166 0 00.008-.074.115.115 0 00-.037-.064 5.958 5.958 0 01-1.38-2.202 5.196 5.196 0 01-.333-1.589 6.915 6.915 0 01.188-2.132c.45-1.484 1.309-2.648 2.577-3.493.282-.188.55-.334.802-.438.286-.12.573-.22.861-.304a.129.129 0 00.087-.087A6.016 6.016 0 015.635 2.31C6.315 1.464 7.132.846 8.086.457zm-.804 7.85a.848.848 0 00-1.473.842l1.694 2.965-1.688 2.848a.849.849 0 001.46.864l1.94-3.272a.849.849 0 00.007-.854l-1.94-3.393zm5.446 6.24a.849.849 0 000 1.695h4.848a.849.849 0 000-1.696h-4.848z' }],
};

const SOURCES = [
  { id: 'local', name: 'Mac Studio', kind: 'local', online: true },
  { id: 'vm', name: '虚拟机', kind: 'ssh', online: true },
  { id: 'gpu', name: 'gpu-server', kind: 'ssh', online: true },
  { id: 'win', name: 'Windows 测试机', kind: 'ssh', online: false },
];

const SESSIONS = [
  ['ccpulse', 'vm', 'claude-code', '世界模式', 'busy'],
  ['ccpulse', 'vm', 'claude-code', '设备与 Agent 详情弹窗', 'idle'],
  ['ccpulse', 'vm', 'claude-code', '苹果 App 审核时长异常', 'waiting'],
  ['ccpulse', 'vm', 'claude-code', 'Playwright 截图报告技能', 'busy'],
  ['ccpulse', 'local', 'claude-code', '远程服务断开提醒', 'idle'],
  ['shop-app', 'vm', 'claude-code', '会员资料编辑', 'busy'],
  ['shop-app', 'vm', 'codex', '远程开发环境配置', 'idle'],
  ['content-studio', 'gpu', 'opencode', '本地模型部署', 'busy'],
  ['content-studio', 'gpu', 'claude-code', '封面图批量重出', 'idle'],
  ['官网', 'local', 'claude-code', '首屏视频轮播', 'busy'],
  ['官网', 'local', 'codex', '下载页三平台', 'idle'],
  ['desktop', 'win', 'claude-code', 'Avalonia 设置页', 'idle'],
  ['desktop', 'vm', 'claude-code', 'Linux Wayland 投递', 'busy'],
];

const REPLIES = [
  '光弧改成在顶点着色器里算贝塞尔，卫星在动也不用每帧重建几何体。',
  '测试全部通过：37 项通过，0 项失败。',
  '已改完并装到你的 Mac 和 iPhone 上，截图发你手机了。',
  '查到原因了：出图要求可用内存至少 11G，现在只剩 7G。我先停掉 27B 模型再出图。',
  '这一版把同类零件全部实例化，几十个会话也只有二十来次绘制。',
  '我需要你确认一下：要不要把旧的设置迁移到新版？',
  '构建失败：Sources/MainWindow.swift 第 612 行类型不匹配，正在修。',
  '发布说明已更新到 CHANGELOG 的 3.49.9 一节。',
  '接口 /api/state 多返回了 sys 字段，世界里的卫星能显示 CPU 和内存了。',
  '重新出图的第一张就失败了，整轮因此停下。现在单独找失败原因。',
];
const THOUGHTS = ['先看一下卫星的轨道半径是不是太大了，镜头拉远时会跑出画面', '用户要的是头顶一直显示最新内容，那小气泡收起时不能消失', '这条消息是排队中的，回显时要按文字去重', '先跑测试再装机，装之前要问一下其他会话'];
const ASKS = ['先看下为什么卡', '可以，按你说的改', '把截图发我手机', '再跑一遍测试', '性能是第一位'];
const TEAMS = [[0, 3, 1], [9, 4]];
const PEER_LINES = ['世界模式的协议文档写好了，你看下 Windows 端怎么接', '收到，我先把 Avalonia 的 WebView 接上', '截图脚本我改好了，你那边直接用', '装机前跟我说一声，我在跑测试', '首屏视频已上线，下载页你来更新'];
const TOOLS = ['Bash', 'Edit', 'Read', 'Grep', 'Write', 'WebSearch', 'Task'];

function fakeShot(seed) {
  const c = document.createElement('canvas');
  c.width = 480; c.height = 320;
  const g = c.getContext('2d');
  g.fillStyle = '#1C1D21'; g.fillRect(0, 0, 480, 320);
  g.fillStyle = '#2A2B30'; g.fillRect(0, 0, 120, 320);
  for (let i = 0; i < 9; i++) { g.fillStyle = i === seed % 9 ? '#D97757' : '#3A3B42'; g.fillRect(12, 16 + i * 32, 96, 20); }
  for (let i = 0; i < 12; i++) {
    g.fillStyle = ['#8A93A3', '#D97757', '#C8C8CC', '#5E9C86'][(i + seed) % 4];
    g.fillRect(140 + (i % 3) * 12, 20 + i * 24, 120 + ((i * 53 + seed * 31) % 180), 10);
  }
  return c.toDataURL('image/png');
}

export function startDemo(world) {
  const params = new URLSearchParams(location.search);
  const still = params.has('shot');
  const lang = params.get('lang') || 'zh';
  world.receive({ type: 'init', lang, strings: {}, brand: '#D97757', quality: 'high', insets: { top: Number(params.get('top') || 0) }, door: params.has('door'), marks: MARKS });
  const now = Date.now();
  const sessions = SESSIONS.map(([project, sourceId, agent, title, activity], i) => ({
    key: `${sourceId}#demo-${i}`,
    title, sourceId, sourceName: SOURCES.find(s => s.id === sourceId).name, agent, activity,
    cwd: `/Users/demo/Documents/${project}`,
    preview: REPLIES[i % REPLIES.length],
    activityText: activity === 'busy' ? TOOLS[i % TOOLS.length] : undefined,
    blocking: activity === 'waiting' ? 'Claude 想运行 Bash：xcrun altool --upload-app' : undefined,
    error: i === 11 ? '构建失败' : undefined,
    usage: { model: i % 3 ? 'claude-opus-5-5' : 'claude-sonnet-5-5', percent: [12, 35, 64, 82, 91, 22, 48][i % 7] },
    effort: ['high', 'xhigh', 'medium'][i % 3],
    subagents: i % 4 === 0 ? 3 : 0,
    startedAt: now - (i + 1) * 23 * 60000,
    updatedAt: now - (i % 5) * 7 * 60000 - (i === 8 ? 40 * 60000 : 0),
  }));
  const faces = { sessions: { [sessions[3].key]: { name: '', avatar: 'emoji:🦊:sand' }, [sessions[9].key]: { name: 'Kite', avatar: 'mark:claude-code:ink' } }, agents: {} };
  const sys = { local: { cpu: 0.18, memUsed: 41e9, memTotal: 128e9 }, vm: { cpu: 0.15, memUsed: 3.5e9, memTotal: 7.7e9 }, gpu: { cpu: 0.13, memUsed: 93e9, memTotal: 124e9 } };
  const state = () => ({ sessions, sources: SOURCES, faces, sys, agents: [] });
  world.receive({ type: 'state', state: state() });
  // 待办（墙上的便签）和今日用量（公司墙的计量牌）
  const src = (i) => ({ key: sessions[i].key, title: sessions[i].title });
  const todos = [
    { id: 't1', text: '墙上的待办便签', agent: true, status: 'pending', source: src(0) },
    { id: 't2', text: '公司墙 token 计量牌', agent: true, status: 'doing', handler: src(0), source: src(0) },
    { id: 't3', text: 'iPhone 上实现世界模式', agent: true, status: 'pending', source: src(3) },
    { id: 't4', text: '在 App Store Connect 换截图', forUser: true, source: src(2) },
    { id: 't5', text: '会员资料导出 Excel', agent: true, status: 'pending', source: src(5) },
    { id: 't6', text: '英文版下载页', agent: true, status: 'pending', source: src(9) },
    { id: 't7', text: 'Windows 安装包签名', agent: true, status: 'doing', handler: src(12), source: src(12) },
  ];
  world.receive({ type: 'todos', items: todos, initial: true });
  const usage = { totals: { input: 12.4e6, output: 2.71e6, cacheRead: 281e6, cacheWrite: 9.2e6, cost: 325.4, requests: 2833 },
    projects: [{ name: 'ccpulse', input: 8e6, output: 1.9e6, cacheRead: 190e6, cacheWrite: 6e6 }, { name: '官网', input: 1e6, output: 0.3e6, cacheRead: 30e6, cacheWrite: 1e6 }] };
  world.receive({ type: 'usage', ...usage });
  if (still) return;
  let todoTick = 0;
  setInterval(() => {
    // 新记一条 → 贴墙；开始做 → 撕下来；做完 → 打勾飞走
    todoTick++;
    const pending = todos.filter(x => x.agent && x.status === 'pending' && !x.done);
    const doing = todos.filter(x => x.status === 'doing' && !x.done);
    if (todoTick % 3 === 1) todos.push({ id: `n${todoTick}`, text: ['补测离线卫星', '光弧颜色跟主题色', '项目牌子显示用量', '截图发手机'][todoTick % 4], agent: true, status: 'pending', source: src([0, 5, 9, 3][todoTick % 4]) });
    else if (todoTick % 3 === 2 && pending.length) { const x = pending[0]; x.status = 'doing'; x.handler = x.source; }
    else if (doing.length) { doing[0].done = true; doing[0].status = 'done'; }
    world.receive({ type: 'todos', items: todos });
    usage.totals.output += 30000; usage.totals.cacheRead += 900000; usage.totals.input += 60000; usage.totals.cost += 0.8; usage.totals.requests += 3;
    world.receive({ type: 'usage', ...usage, totals: { ...usage.totals } });
  }, 7000);

  let tick = 0;
  setInterval(() => {
    tick++;
    const s = sessions[Math.floor(Math.random() * sessions.length)];
    const ts = Date.now();
    const roll = Math.random();
    if (roll < 0.25) {
      world.receive({ type: 'entries', key: s.key, items: [{ t: 'thinking', id: `k${tick}`, ts, text: THOUGHTS[tick % THOUGHTS.length] }] });
    } else if (roll < 0.5) {
      world.receive({ type: 'entries', key: s.key, items: [{ t: 'tool', id: `t${tick}`, ts, name: TOOLS[tick % TOOLS.length], brief: 'Bash: npm test -- --watch=false' }, { t: 'text', id: `x${tick}`, ts: ts + 1, text: REPLIES[tick % REPLIES.length] }] });
    } else if (roll < 0.65) {
      world.receive({ type: 'entries', key: s.key, items: [{ t: 'user', id: `u${tick}`, ts, text: ASKS[tick % ASKS.length] }] });
    } else if (roll < 0.75) {
      world.receive({ type: 'entries', key: s.key, items: [{ t: 'agent_image', id: `o${tick}`, ts, text: '截图', images: [{ ref: 'demo', url: fakeShot(tick) }] }] });
    } else if (roll < 0.85) {
      // agent 之间发消息：两拨人各聊各的（三个人在同一片，两个人隔得远）
      const team = TEAMS[tick % TEAMS.length].map(i => sessions[i].key);
      const from = team[tick % team.length], to = team[(tick + 1) % team.length];
      world.receive({ type: 'peers', links: [{ id: `p${tick}`, from, to, sentAt: ts, summary: PEER_LINES[tick % PEER_LINES.length] }] });
    } else {
      // 换个状态
      const next = ['busy', 'idle', 'busy', 'waiting'][tick % 4];
      s.activity = next;
      s.activityText = next === 'busy' ? TOOLS[tick % TOOLS.length] : undefined;
      s.blocking = next === 'waiting' ? 'Claude 想编辑 Sources/WorldView.swift' : undefined;
      s.updatedAt = ts;
      world.receive({ type: 'state', state: state() });
    }
  }, 2600);
}
