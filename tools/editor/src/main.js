// Kiteline 代码编辑器：iPhone / iPad / Mac 的代码 IDE 里那块编辑区（WKWebView 里跑）。
// App 通过 window.KL 调用（打开文件、取内容、对比……），这边通过 webkit.messageHandlers.kl 回报（改动、光标、保存快捷键）
import { EditorState, Compartment, StateField, StateEffect, RangeSet } from "@codemirror/state";
import {
  EditorView, keymap, lineNumbers, highlightActiveLineGutter, highlightSpecialChars, drawSelection, dropCursor,
  rectangularSelection, crosshairCursor, highlightActiveLine, gutter, GutterMarker, ViewPlugin, highlightWhitespace,
} from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentWithTab, undo, redo, indentMore, indentLess, toggleComment, selectAll } from "@codemirror/commands";
import { foldGutter, foldKeymap, indentOnInput, syntaxHighlighting, bracketMatching, indentUnit, foldAll, unfoldAll, defaultHighlightStyle } from "@codemirror/language";
import { searchKeymap, highlightSelectionMatches, openSearchPanel, closeSearchPanel, gotoLine, search, SearchQuery, setSearchQuery, findNext, findPrevious, replaceAll } from "@codemirror/search";
import { autocompletion, completionKeymap, closeBrackets, closeBracketsKeymap, completeAnyWord } from "@codemirror/autocomplete";
import { MergeView, unifiedMergeView, Chunk } from "@codemirror/merge";
import { showMinimap } from "@replit/codemirror-minimap";
import { languageFor } from "./langs.js";
import { editorTheme, highlightStyle } from "./theme.js";

function post(message) {
  try {
    window.webkit.messageHandlers.kl.postMessage(message);
  } catch (e) {
    if (window.chrome && window.chrome.webview) window.chrome.webview.postMessage(message);
    else console.log("KL →", message);
  }
}
window.addEventListener("error", (e) => post({ type: "error", message: String(e.message || e) }));

const host = document.getElementById("editor");
const opts = { dark: matchMedia("(prefers-color-scheme: dark)").matches, fontSize: 13, wrap: false, readOnly: false, minimap: false, bg: null,
  lang: (navigator.language || "").toLowerCase().startsWith("zh") ? "zh" : "en" };

const themeC = new Compartment(), langC = new Compartment(), readOnlyC = new Compartment(), wrapC = new Compartment();
const indentC = new Compartment(), minimapC = new Compartment(), whitespaceC = new Compartment();

let view = null;
let merge = null;          // 对比时的 MergeView / 合并视图
// 打开的标签：id → { state, saved（上次保存或打开时的内容，判断改没改过）, path, language, indent, dirty }
// 切标签时把编辑器状态整个存起来，撤销历史、光标、折叠都跟着标签走（同 VS Code）
const tabs = new Map();
let activeId = null;
const active = () => tabs.get(activeId);

// ---------------- 改动标记（行号右边的竖条，和 VS Code 一样对比暂存区里的版本） ----------------

const setBaseline = StateEffect.define();
const setMarks = StateEffect.define();
class Bar extends GutterMarker {
  constructor(kind) { super(); this.kind = kind; }
  eq(other) { return other.kind === this.kind; }
  toDOM() { const el = document.createElement("div"); el.className = "kl-git-" + this.kind; return el; }
}
const ADD = new Bar("add"), MOD = new Bar("mod"), DEL = new Bar("del");

const baselineField = StateField.define({
  create: () => null,
  update(value, tr) {
    for (const e of tr.effects) if (e.is(setBaseline)) value = e.value;
    return value;
  },
});
const marksField = StateField.define({
  create: () => RangeSet.empty,
  update(value, tr) {
    for (const e of tr.effects) if (e.is(setMarks)) return e.value;
    return tr.docChanged ? value.map(tr.changes) : value;
  },
});

function computeMarks(state) {
  const base = state.field(baselineField, false);
  if (base == null) return RangeSet.empty;
  const doc = state.doc;
  const marks = [];
  for (const chunk of Chunk.build(base, doc)) {
    if (chunk.fromB === chunk.toB) {
      const line = doc.lineAt(Math.min(chunk.fromB, doc.length));
      marks.push(DEL.range(line.from));
      continue;
    }
    const kind = chunk.fromA === chunk.toA ? ADD : MOD;
    const first = doc.lineAt(chunk.fromB).number;
    const last = doc.lineAt(Math.max(chunk.fromB, Math.min(chunk.toB - 1, doc.length))).number;
    for (let n = first; n <= last; n++) marks.push(kind.range(doc.line(n).from));
  }
  return RangeSet.of(marks, true);
}

const marksUpdater = ViewPlugin.fromClass(class {
  constructor(v) { this.timer = null; this.schedule(v, 0); }
  update(u) {
    if (u.docChanged || u.transactions.some((tr) => tr.effects.some((e) => e.is(setBaseline)))) this.schedule(u.view, 350);
  }
  schedule(v, delay) {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      if (v.state.field(baselineField, false) === undefined) return;
      v.dispatch({ effects: setMarks.of(computeMarks(v.state)) });
    }, delay);
  }
  destroy() { clearTimeout(this.timer); }
});

const gitGutter = [
  baselineField, marksField, marksUpdater,
  gutter({ class: "kl-git-gutter", markers: (v) => v.state.field(marksField) }),
];

// ---------------- 编辑器 ----------------

function detectIndent(text) {
  let tabs = 0, spaces = 0;
  const widths = {};
  const lines = text.split("\n", 2000);
  let prev = 0;
  for (const line of lines) {
    if (!line.trim()) continue;
    if (line[0] === "\t") { tabs++; continue; }
    const n = line.length - line.trimStart().length;
    if (n > 0 && line[0] === " ") spaces++;
    const delta = Math.abs(n - prev);
    if (delta === 2 || delta === 4 || delta === 8) widths[delta] = (widths[delta] || 0) + 1;
    prev = n;
  }
  if (tabs > spaces) return { unit: "\t", label: "Tab", size: 4 };
  const best = Object.keys(widths).sort((a, b) => widths[b] - widths[a])[0];
  const size = best ? Number(best) : 4;
  return { unit: " ".repeat(size), label: "Spaces: " + size, size };
}

// CodeMirror 自带的字（查找面板、跳到行、折叠、对比里「未改动的行」）：中文界面换成中文
const ZH = {
  "Find": "查找", "Replace": "替换", "next": "下一个", "previous": "上一个", "all": "全部", "match case": "区分大小写",
  "regexp": "正则", "by word": "全字匹配", "replace": "替换", "replace all": "全部替换", "close": "关闭",
  "Go to line": "跳到行", "go": "跳转", "Folded lines": "已折叠的行", "Unfold line": "展开", "Fold line": "折叠",
  "Control character": "控制字符", "current match": "当前匹配", "on line": "行", "replaced match on line $": "已替换第 $ 行的匹配",
  "replaced $ matches": "已替换 $ 处", "Completions": "补全", "$ unchanged lines": "$ 行未改动", "Accept": "接受", "Reject": "拒绝",
  "Selection deleted": "已删除所选内容",
};
const phrases = () => (opts.lang === "zh" ? EditorState.phrases.of(ZH) : []);

function themeExtensions() {
  return [editorTheme(opts.dark, opts), syntaxHighlighting(highlightStyle(opts.dark)), syntaxHighlighting(defaultHighlightStyle, { fallback: true })];
}

function minimapExtension() {
  if (!opts.minimap) return [];
  return showMinimap.compute(["doc"], () => ({
    create: () => ({ dom: document.createElement("div") }),
    displayText: "blocks",
    showOverlay: "mouse-over",
  }));
}

function readOnlyExtension() {
  return [EditorState.readOnly.of(opts.readOnly), EditorView.editable.of(!opts.readOnly)];
}

let cursorTimer = null;
const reporter = EditorView.updateListener.of((u) => {
  const tab = active();
  if (u.docChanged && tab) {
    const dirty = !u.state.doc.eq(tab.saved);
    if (dirty !== tab.dirty) {
      tab.dirty = dirty;
      post({ type: "change", id: activeId, dirty });
    }
  }
  if (u.selectionSet || u.docChanged) {
    clearTimeout(cursorTimer);
    cursorTimer = setTimeout(() => {
      const s = u.view.state;
      const head = s.selection.main.head;
      const line = s.doc.lineAt(head);
      const selected = s.selection.ranges.reduce((n, r) => n + (r.to - r.from), 0);
      post({ type: "cursor", id: activeId, line: line.number, col: head - line.from + 1, selected, lines: s.doc.lines, cursors: s.selection.ranges.length });
    }, 120);
  }
});

const saveKeys = keymap.of([
  { key: "Mod-s", preventDefault: true, run: () => { post({ type: "save", id: activeId }); return true; } },
  { key: "Mod-/", run: toggleComment },
  { key: "Mod-g", preventDefault: true, run: gotoLine },
]);

function baseExtensions(indent, support) {
  return [
    lineNumbers(), gitGutter, foldGutter({ openText: "⌄", closedText: "›" }), highlightActiveLineGutter(), highlightSpecialChars(),
    history(), drawSelection(), dropCursor(), EditorState.allowMultipleSelections.of(true), indentOnInput(), bracketMatching(),
    closeBrackets(), autocompletion({ override: null, activateOnTyping: true, icons: true }), rectangularSelection(), crosshairCursor(),
    highlightActiveLine(), highlightSelectionMatches(), search({ top: true }),
    keymap.of([...closeBracketsKeymap, ...defaultKeymap, ...searchKeymap, ...historyKeymap, ...foldKeymap, ...completionKeymap, indentWithTab]),
    saveKeys,
    EditorView.contentAttributes.of({ autocorrect: "off", autocapitalize: "off", spellcheck: "false", translate: "no" }),
    themeC.of(themeExtensions()),
    phrases(),
    langC.of(support ? [support, EditorState.languageData.of(() => [{ autocomplete: completeAnyWord }])] : EditorState.languageData.of(() => [{ autocomplete: completeAnyWord }])),
    readOnlyC.of(readOnlyExtension()),
    wrapC.of(opts.wrap ? EditorView.lineWrapping : []),
    indentC.of([indentUnit.of(indent.unit), EditorState.tabSize.of(indent.size)]),
    minimapC.of(minimapExtension()),
    whitespaceC.of(opts.whitespace ? highlightWhitespace() : []),
    reporter,
  ];
}

function destroyMerge() {
  if (merge) {
    merge.destroy();
    merge = null;
  }
  document.getElementById("diff").innerHTML = "";
  document.getElementById("diff").style.display = "none";
  host.style.display = "block";
}

function apply(next) {
  for (const key of Object.keys(next || {})) if (next[key] !== undefined && next[key] !== null) opts[key] = next[key];
  if (next && next.bg === null) opts.bg = null;
  const bg = opts.bg || (opts.dark ? "#1F1F1F" : "#FFFFFF");
  document.documentElement.style.background = bg;
  document.body.style.background = bg;
  document.documentElement.style.colorScheme = opts.dark ? "dark" : "light";
}

function reconfigure() {
  view.dispatch({ effects: [
    themeC.reconfigure(themeExtensions()), readOnlyC.reconfigure(readOnlyExtension()),
    wrapC.reconfigure(opts.wrap ? EditorView.lineWrapping : []), minimapC.reconfigure(minimapExtension()),
    whitespaceC.reconfigure(opts.whitespace ? highlightWhitespace() : []),
  ] });
}

function activate(id) {
  const tab = tabs.get(id);
  if (!tab) return false;
  destroyMerge();
  const prev = active();
  if (prev && view && activeId !== id) prev.state = view.state;
  if (!view) view = new EditorView({ state: tab.state, parent: host });
  else if (activeId !== id || view.state !== tab.state) view.setState(tab.state);
  activeId = id;
  reconfigure();   // 存起来的状态可能是换主题、字号之前的
  post({ type: "info", id, language: tab.language, indent: tab.indent, lines: view.state.doc.lines });
  post({ type: "change", id, dirty: !!tab.dirty });
  return true;
}

const KL = {
  /** 打开一个文件（新开或替换同 id 的标签）：{id, text, path, readOnly, dark, fontSize, wrap, minimap, line, column, bg, baseline} */
  open(o) {
    apply(o);
    const id = o.id || o.path || "untitled";
    const text = o.text || "";
    const lang = languageFor(o.path);
    const indent = detectIndent(text);
    const state = EditorState.create({ doc: text, extensions: baseExtensions(indent, lang.support) });
    if (activeId === id) activeId = null;   // 同一个标签重新载入：别把旧状态存回去
    tabs.set(id, { state, saved: state.doc, path: o.path || "", language: lang.label, indent: indent.label, dirty: false });
    activate(id);
    if (typeof o.baseline === "string") KL.setBaseline(o.baseline);
    if (o.line) KL.gotoLine(o.line, o.column);
    else view.scrollDOM.scrollTop = 0;
    return lang.label;
  },
  /** 切到已经开着的标签 */
  show(id) { return activate(id); },
  /** 关掉标签（App 那边已经问过要不要保存） */
  close(id) {
    tabs.delete(id);
    if (activeId === id) activeId = null;
  },
  has(id) { return tabs.has(id); },
  /** 外观、只读、换行、小地图：{dark, fontSize, wrap, readOnly, minimap, bg, whitespace} */
  setOptions(o) {
    apply(o);
    if (merge || !view) return;
    reconfigure();
  },
  getText(id) {
    if (!id || id === activeId) return view ? view.state.doc.toString() : "";
    const tab = tabs.get(id);
    return tab ? tab.state.doc.toString() : "";
  },
  isDirty(id) {
    const tab = tabs.get(id || activeId);
    if (!tab) return false;
    const doc = (id || activeId) === activeId && view ? view.state.doc : tab.state.doc;
    return !doc.eq(tab.saved);
  },
  /** 保存成功：当前内容就是磁盘上的了（text 是保存时取的那份，保存期间又打的字仍算没保存） */
  markSaved(id, text, baseline) {
    const key = id || activeId;
    const tab = tabs.get(key);
    if (!tab) return;
    tab.saved = typeof text === "string" ? EditorState.create({ doc: text }).doc : (key === activeId && view ? view.state.doc : tab.state.doc);
    const doc = key === activeId && view ? view.state.doc : tab.state.doc;
    tab.dirty = !doc.eq(tab.saved);
    post({ type: "change", id: key, dirty: tab.dirty });
    if (typeof baseline === "string" && key === activeId) KL.setBaseline(baseline);
  },
  /** 改动标记对比的底稿（暂存区里的版本）；null 去掉 */
  setBaseline(text) {
    if (!view) return;
    view.dispatch({ effects: setBaseline.of(text == null ? null : view.state.toText(text)) });
  },
  /** 换成磁盘上的最新内容（文件在外面被改了，选「载入磁盘上的版本」） */
  replaceAll(text) {
    const tab = active();
    if (!view || !tab) return;
    view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text } });
    tab.saved = view.state.doc;
    tab.dirty = false;
    post({ type: "change", id: activeId, dirty: false });
  },
  gotoLine(line, column) {
    if (!view) return;
    const n = Math.max(1, Math.min(view.state.doc.lines, line | 0));
    const l = view.state.doc.line(n);
    const pos = Math.min(l.to, l.from + Math.max(0, (column | 0) - 1));
    view.dispatch({ selection: { anchor: pos, head: column ? pos : l.to }, effects: EditorView.scrollIntoView(pos, { y: "center" }) });
  },
  /** 工具栏 / 键盘上方那排按钮 */
  command(name, arg) {
    if (merge && name !== "blur") return false;
    if (!view) return false;
    const run = {
      undo, redo, selectAll, indentMore, indentLess, toggleComment, foldAll, unfoldAll, gotoLine, findNext, findPrevious, replaceAll,
      find: (v) => { openSearchPanel(v); if (arg) v.dispatch({ effects: setSearchQuery.of(new SearchQuery({ search: arg })) }); return true; },
      closeFind: closeSearchPanel,
      focus: (v) => { v.focus(); return true; },
      blur: () => { if (document.activeElement) document.activeElement.blur(); return true; },
    }[name];
    return run ? run(view) : false;
  },
  /** 键盘上方那排符号键：Tab 按缩进单位缩进 */
  insert(text) {
    if (!view || opts.readOnly || merge) return;
    if (text === "\t") {
      if (!view.state.selection.main.empty) return indentMore(view);
      text = view.state.facet(indentUnit);
    }
    view.dispatch(view.state.replaceSelection(text), { scrollIntoView: true, userEvent: "input.type" });
    view.focus();
  },
  /** 对比：{original, modified, path, split, dark, fontSize, collapse} —— 并排（宽屏）或上下合在一起（手机） */
  diff(o) {
    apply(o);
    const prev = active();
    if (prev && view) prev.state = view.state;
    activeId = null;
    const lang = languageFor(o.path);
    const common = (readOnly) => [
      lineNumbers(), highlightSpecialChars(), drawSelection(), EditorState.readOnly.of(readOnly), EditorView.editable.of(!readOnly),
      themeC.of(themeExtensions()), phrases(), lang.support ? lang.support : [], opts.wrap ? EditorView.lineWrapping : [], search({ top: true }),
      keymap.of([...defaultKeymap, ...searchKeymap]),
    ];
    if (merge) merge.destroy();
    const box = document.getElementById("diff");
    box.innerHTML = "";
    box.style.display = "block";
    host.style.display = "none";
    const collapse = o.collapse === false ? undefined : { margin: 3, minSize: 6 };
    if (o.split) {
      merge = new MergeView({
        a: { doc: o.original || "", extensions: common(true) },
        b: { doc: o.modified || "", extensions: common(true) },
        parent: box, collapseUnchanged: collapse, highlightChanges: true, gutter: true,
      });
    } else {
      merge = new EditorView({
        doc: o.modified || "",
        extensions: [...common(true), unifiedMergeView({ original: o.original || "", mergeControls: false, highlightChanges: true, gutter: true, collapseUnchanged: collapse })],
        parent: box,
      });
    }
    // 第一处改动滚到眼前
    setTimeout(() => {
      const first = document.querySelector("#diff .cm-changedLine, #diff .cm-deletedChunk, #diff .cm-insertedLine");
      if (first) first.scrollIntoView({ block: "center" });
    }, 60);
    const chunks = Chunk.build(EditorState.create({ doc: o.original || "" }).doc, EditorState.create({ doc: o.modified || "" }).doc);
    post({ type: "diff", chunks: chunks.length, language: lang.label });
    return chunks.length;
  },
  /** 跳到下一处 / 上一处改动（对比时） */
  nextChange(dir) {
    const list = Array.from(document.querySelectorAll("#diff .cm-changedLine, #diff .cm-deletedChunk, #diff .cm-insertedLine"));
    if (!list.length) return;
    const box = document.getElementById("diff");
    const mid = box.getBoundingClientRect().top + box.clientHeight / 2;
    const target = dir < 0 ? list.reverse().find((el) => el.getBoundingClientRect().top < mid - 8)
      : list.find((el) => el.getBoundingClientRect().top > mid + 8);
    (target || list[0]).scrollIntoView({ block: "center", behavior: "smooth" });
  },
  /** 退出对比，回到编辑 */
  closeDiff() { destroyMerge(); },
  info() {
    const tab = active();
    return tab ? { id: activeId, path: tab.path, language: tab.language, indent: tab.indent, lines: view.state.doc.lines } : null;
  },
};
window.KL = KL;
post({ type: "ready" });
