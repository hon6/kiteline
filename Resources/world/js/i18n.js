// 界面文字：中文是原文；英文由主程序在 init 里给（各端都从 i18n/en.json 那一张表来，见 Sources/WorldView.swift 的 strings），
// 网页里不另存一份译文。%@ 按顺序换成参数。

let table = {};
export let lang = 'zh';

export function setStrings(code, strings) {
  lang = code || 'zh';
  table = strings || {};
}

export function t(text, ...args) {
  let out = table[text] || text;
  for (const arg of args) out = out.replace('%@', String(arg));
  // 英文：数字正好是 1 时，紧跟的复数词换成单数（1 sessions → 1 session）；译文表只有一种写法
  if (lang === 'en' && args.length) out = out.replace(/(^|[^\d.\/])1 ([A-Za-z]*[^\Ws])s\b/g, '$11 $2');
  return out;
}
