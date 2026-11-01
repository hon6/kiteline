// 世界里的数据：直接吃 Kiteline 接口的格式（/api/state 整份、实时事件 entries / peers / sys），
// 各端主程序（Mac、iPhone、Windows、Linux）只管原样转进来，不用各自再拼一套。

import { t } from './i18n.js';

/// 会话现在的样子（只留世界要画、要显示的）
function normalize(raw, faces) {
  const cwd = raw.cwd || '';
  const folder = cwd.split(/[\\/]/).filter(Boolean).pop() || raw.cwdShort || t('未命名项目');
  const activity = ['busy', 'waiting', 'idle'].includes(raw.activity) ? raw.activity : 'idle';
  const usage = raw.usage || {};
  return {
    key: raw.key,
    title: raw.title || raw.name || t('会话'),
    sourceId: raw.sourceId || '',
    sourceName: raw.sourceName || '',
    project: folder,
    cwd,
    activity,
    failed: !!raw.error,
    error: raw.error || '',
    // 第二行：等你确认的原因 / 正在做什么 / 最后一句结论
    line: activity === 'waiting' ? (raw.blocking || t('需要确认'))
      : activity === 'busy' ? (raw.activityText ? t('正在 %@', raw.activityText) : (raw.reason || t('正在工作…')))
      : (raw.error ? t('出错已停止：%@', raw.error) : (raw.preview || raw.reason || '')),
    preview: raw.preview || '',
    activityText: raw.activityText || '',
    // 这一轮做到第几步：「2/4 开发中」（电脑只在忙、等确认时给）
    stage: raw.stage && raw.stage.step && raw.stage.total && activity !== 'idle'
      ? `${raw.stage.part ? raw.stage.part + ' · ' : ''}${raw.stage.step}/${raw.stage.total} ${t(raw.stage.label || '')}` : '',
    pendingTool: raw.pendingTool || '',
    agent: raw.agent || 'claude-code',
    model: modelName(usage.model),
    effort: raw.effort || '',
    context: typeof usage.percent === 'number' ? usage.percent : null,
    subagents: raw.subagents || 0,
    startedAt: raw.startedAt || 0,
    updatedAt: raw.updatedAt || 0,
    readOnly: !!raw.readOnly,
    face: (faces.sessions || {})[raw.key] || null,
  };
}

/// claude-opus-5-5 → Opus 5.5（同 Mac 的 SessionItem.modelName）
export function modelName(id) {
  if (!id) return '';
  const parts = id.replace('claude-', '').split('-');
  const family = parts.shift() || id;
  const version = [];
  for (const p of parts) { if (/^\d{1,2}$/.test(p)) version.push(p); else break; }
  return family.charAt(0).toUpperCase() + family.slice(1) + (version.length ? ' ' + version.join('.') : '');
}

export class WorldData {
  constructor() {
    this.sessions = new Map();
    this.sources = new Map();
    this.agentCards = new Map();
    this.faces = { sessions: {}, agents: {} };
    this.sys = {};
    this.marked = new Set();
    /// 每个会话最近一条消息（气泡、动态里用）：{role, text, images, ts}
    this.latest = new Map();
    /// 项目第一次出现的先后：项目区按它排，会话来来去去时别的项目不挪位置
    this.projectOrder = [];
    try { this.projectOrder = JSON.parse(localStorage.getItem('world.projects') || '[]'); } catch { /* 隐私模式等 */ }
  }

  /// 整份状态；返回会话有没有增减（增减了要重新排位置）
  applyState(state) {
    this.faces = state.faces || this.faces;
    if (state.sys) this.sys = state.sys;
    this.marked = new Set(state.marked || []);
    for (const card of state.agents || []) if (card && card.id) this.agentCards.set(card.id, card);
    const sources = new Map();
    for (const s of state.sources || []) sources.set(s.id, { id: s.id, name: s.name || s.id, kind: s.kind || '', online: !!s.online, status: s.status || '' });
    this.sources = sources;

    const next = new Map();
    for (const raw of state.sessions || []) {
      if (!raw || !raw.key) continue;
      const s = normalize(raw, this.faces);
      next.set(s.key, s);
      // 最后一句结论当成「最近一条消息」（世界刚打开时人人头顶都有话）
      if (!this.latest.has(s.key) && s.preview) this.latest.set(s.key, { role: 'assistant', text: s.preview, images: [], ts: s.updatedAt || 0, old: true });
    }
    const added = [...next.keys()].filter(k => !this.sessions.has(k));
    const removed = [...this.sessions.keys()].filter(k => !next.has(k));
    // 换了项目（cwd 变了）也要重排
    const moved = [...next.values()].some(s => this.sessions.has(s.key) && this.sessions.get(s.key).project !== s.project);
    this.sessions = next;
    for (const k of removed) this.latest.delete(k);
    let grew = false;
    for (const s of next.values()) if (!this.projectOrder.includes(s.project)) { this.projectOrder.push(s.project); grew = true; }
    if (grew) {
      // 只留最近 200 个项目的先后
      this.projectOrder = this.projectOrder.slice(-200);
      try { localStorage.setItem('world.projects', JSON.stringify(this.projectOrder)); } catch { /* 存不了就算了 */ }
    }
    return { added, removed, relayout: added.length > 0 || removed.length > 0 || moved };
  }

  /// 对话增量：挑出刚到的回复、你发的话、图、工具调用（旧记录只更新「最近一条」，不放动画）
  applyEntries(key, items) {
    if (!this.sessions.has(key) || !Array.isArray(items) || !items.length) return [];
    const now = Date.now();
    const fresh = items
      .filter(i => i && i.t)
      .sort((a, b) => (a.ts || 0) - (b.ts || 0));
    const events = [];
    for (const item of fresh) {
      const ts = item.ts || now;
      const recent = now - ts < 120000;
      const images = (item.images || []).filter(i => i && i.ref).map(i => ({ ref: i.ref, name: i.name || '', url: i.url }));
      if (item.t === 'text' && (item.text || '').trim()) {
        this.remember(key, { role: 'assistant', text: item.text, images: [], ts });
        if (recent) events.push({ kind: 'assistant', key, text: item.text, images: [], ts, id: item.id });
      } else if (item.t === 'user' && ((item.text || '').trim() || images.length)) {
        // 排队中的（他在忙时你发的）也算：你说的话要马上看得到；后面正式回显时按文字去重
        this.remember(key, { role: 'user', text: item.text || '', images, ts });
        if (recent) events.push({ kind: 'user', key, text: item.text || '', images, ts, id: item.id });
      } else if ((item.t === 'agent_image' || item.t === 'result') && images.length) {
        this.remember(key, { role: 'assistant', text: item.text || '', images, ts });
        if (recent) events.push({ kind: 'image', key, text: item.text || '', images, ts, id: item.id });
      } else if (item.t === 'tool' && item.name && recent) {
        // brief 常带着「Bash: …」：去掉重复的工具名
        const brief = String(item.brief || '').replace(new RegExp('^' + item.name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\s*[:：]\\s*'), '');
        events.push({ kind: 'tool', key, name: item.name, brief, ts, id: item.id });
      } else if (item.t === 'thinking' && (item.text || '').trim() && recent) {
        events.push({ kind: 'think', key, text: item.text, ts, id: item.id });
      }
    }
    return events;
  }

  remember(key, message) {
    const was = this.latest.get(key);
    if (was && !was.old && (was.ts || 0) > (message.ts || 0)) return;
    this.latest.set(key, message);
  }

  /// 会话之间的消息（SendMessage）：from / to 是会话 key
  applyPeers(links, backfill) {
    if (!Array.isArray(links)) return [];
    this.seenPeers ??= new Set();
    const now = Date.now();
    const out = [];
    for (const l of links) {
      if (!l || !l.from || !l.to) continue;
      // 同一封信发出、读到各报一次：只飞一次
      const id = l.msgId || l.id || (l.from + '>' + l.to + '@' + (l.sentAt || ''));
      if (this.seenPeers.has(id)) continue;
      this.seenPeers.add(id);
      if (backfill || !this.sessions.has(l.from) || !this.sessions.has(l.to) || now - (l.sentAt || l.readAt || now) > 120000) continue;
      out.push({ id, from: l.from, to: l.to, summary: l.summary || l.text || '' });
    }
    if (this.seenPeers.size > 2000) this.seenPeers = new Set([...this.seenPeers].slice(-1000));
    return out;
  }

  applySys(id, stats) {
    if (!id) return;
    if (stats) this.sys[id] = stats; else delete this.sys[id];
  }

  agentName(id) {
    const card = this.agentCards.get(id);
    if (card && card.name) return card.name;
    return AGENT_NAMES[id] || id;
  }

  /// 统计（左上角那排）
  totals() {
    const list = [...this.sessions.values()];
    const sources = [...this.sources.values()];
    return {
      sessions: list.length,
      busy: list.filter(s => s.activity === 'busy').length,
      waiting: list.filter(s => s.activity === 'waiting').length,
      failed: list.filter(s => s.failed).length,
      online: sources.filter(s => s.online).length,
      sources: sources.length,
      agents: new Set(list.map(s => s.agent)).size,
      projects: new Set(list.map(s => s.project)).size,
    };
  }
}

/// 内置的 agent 名称（同 KitelineKit/Shared/AgentMark.swift 的 Agents.all；插件给的从 state.agents 来）
export const AGENT_NAMES = {
  'claude-code': 'Claude Code', codex: 'Codex', copilot: 'GitHub Copilot', cursor: 'Cursor', 'gemini-cli': 'Gemini CLI',
  antigravity: 'Antigravity', opencode: 'OpenCode', 'qwen-code': 'Qwen Code', 'kimi-cli': 'Kimi CLI', cline: 'Cline',
  'roo-code': 'Roo Code', 'kilo-code': 'Kilo Code', kiro: 'Kiro', windsurf: 'Windsurf', amp: 'Amp', goose: 'Goose',
  trae: 'Trae', qoder: 'Qoder', 'deepseek-harness': 'DeepSeek Harness', proma: 'Proma',
};
