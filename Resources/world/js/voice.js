// 朗读 agent 之间的交谈：主程序合成语音（kiteline-world://app/tts，装了微软神经语音就用它，否则系统语音），这里 2 倍速播放（音调不变）。
// 每个会话固定一种声音（按 key 挑）。排队念：一句念完才念下一句，新来的不打断正在念的（10-27：说两个字就断了）；
// 积压太多时丢掉最早还没念的。世界看不见时不念。没有主程序（浏览器演示）时用浏览器自带的语音。

import { hashOf } from './office.js';

export class Voice {
  constructor(world) {
    this.world = world;
    this.voices = [];
    this.queue = [];
    this.current = null;
    try { this.on = localStorage.getItem('world.voice') !== '0'; } catch { this.on = true; }
  }

  setVoices(list) { this.voices = Array.isArray(list) ? list : []; }

  browserSpeak(text, end) {
    if (typeof speechSynthesis === 'undefined') { end(); return; }
    const u = new SpeechSynthesisUtterance(text);
    u.lang = 'zh-CN';
    u.rate = 2;
    u.onend = end;
    u.onerror = end;
    speechSynthesis.speak(u);
  }

  toggle() {
    this.on = !this.on;
    try { localStorage.setItem('world.voice', this.on ? '1' : '0'); } catch { /* 无痕模式 */ }
    if (!this.on) this.stop();
    return this.on;
  }

  /// 全停：正在念的停下，排着的都不念了（离开世界、关朗读）
  stop() {
    const pending = this.queue.splice(0);
    if (this.audio) { this.audio.pause(); this.audio = null; }
    if (typeof speechSynthesis !== 'undefined') speechSynthesis.cancel();
    this.finish?.();
    for (const item of pending) item.resolve();
  }

  /// 排队念一句：轮到它开始念时调 onStart，念完（或念不了、被丢掉）时 resolve
  speak(key, text, { onStart } = {}) {
    const clean = String(text || '').replace(/[*_`#>]+/g, '').replace(/\s+/g, ' ').trim().slice(0, 300);
    if (!this.on || !clean || !this.world.visible || document.hidden) return Promise.resolve();
    return new Promise((resolve) => {
      this.queue.push({ key, text: clean, onStart, resolve });
      // 积压超过 5 句就丢掉最早还没念的：落后太多，念的都是早就过去的话
      while (this.queue.length > 5) this.queue.shift().resolve();
      this.next();
    });
  }

  next() {
    if (this.current || !this.queue.length) return;
    const item = this.queue.shift();
    this.current = item;
    let done = false, timer = 0;
    const end = () => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      this.audio = null;
      this.finish = null;
      this.current = null;
      item.resolve();
      this.next();
    };
    this.finish = end;
    // 兜底：合成卡住、播放没回音也别一直占着（2 倍速一个字约 0.15 秒，再留出合成的时间）
    timer = setTimeout(end, 12000 + item.text.length * 250);
    item.onStart?.();
    const voice = this.voices.length ? this.voices[Math.floor(hashOf(item.key) * 9973) % this.voices.length] : '';
    const play = (src) => {
      if (done) return;
      const audio = new Audio(src);
      audio.playbackRate = 2;
      audio.preservesPitch = true;
      audio.onended = end;
      audio.onerror = end;
      this.audio = audio;
      audio.play().catch(end);
    };
    if (this.world.api) {
      // 直连模式：电脑端后台合成（POST /api/tts），合成不了用浏览器自带语音
      this.world.api.tts(item.text, voice).then(play).catch(() => { if (!done) this.browserSpeak(item.text, end); });
    } else if (this.world.host.connected) {
      play(this.world.mediaBase + 'tts?voice=' + encodeURIComponent(voice) + '&text=' + encodeURIComponent(item.text));
    } else this.browserSpeak(item.text, end);
  }
}
