// VS Code 的配色：深色是 Dark Modern（编辑器底 #1F1F1F）+ Dark+ 的语法色，浅色是 Light Modern + Light+ 的语法色
import { EditorView } from "@codemirror/view";
import { HighlightStyle } from "@codemirror/language";
import { tags as t } from "@lezer/highlight";

const DARK = {
  bg: "#1F1F1F", fg: "#CCCCCC", gutter: "#6E7681", gutterActive: "#CCCCCC", activeLine: "rgba(255,255,255,0.04)",
  selection: "#264F78", selectionBlur: "#3A3D41", cursor: "#AEAFAD", match: "rgba(158,106,3,0.55)", matchSelected: "rgba(81,92,106,0.9)",
  bracket: "rgba(0,100,0,0.25)", bracketBorder: "#888888", panel: "#181818", panelBorder: "#2B2B2B", input: "#313131", inputBorder: "#3C3C3C",
  tooltip: "#202020", fold: "#C5C5C5", inserted: "rgba(46,160,67,0.18)", deleted: "rgba(248,81,73,0.18)",
  insertedText: "rgba(46,160,67,0.40)", deletedText: "rgba(248,81,73,0.40)", gitAdd: "#2EA043", gitMod: "#0078D4", gitDel: "#F85149",
  accent: "#0078D4", whitespace: "rgba(227,228,226,0.16)",
};
const LIGHT = {
  bg: "#FFFFFF", fg: "#3B3B3B", gutter: "#6E7681", gutterActive: "#171184", activeLine: "rgba(0,0,0,0.035)",
  selection: "#ADD6FF", selectionBlur: "#E5EBF1", cursor: "#000000", match: "rgba(234,92,0,0.33)", matchSelected: "rgba(165,180,197,0.7)",
  bracket: "rgba(0,100,0,0.1)", bracketBorder: "#B9B9B9", panel: "#F8F8F8", panelBorder: "#E5E5E5", input: "#FFFFFF", inputBorder: "#CECECE",
  tooltip: "#F8F8F8", fold: "#424242", inserted: "rgba(46,160,67,0.14)", deleted: "rgba(248,81,73,0.13)",
  insertedText: "rgba(46,160,67,0.32)", deletedText: "rgba(248,81,73,0.30)", gitAdd: "#2EA043", gitMod: "#005FB8", gitDel: "#F85149",
  accent: "#005FB8", whitespace: "rgba(51,51,51,0.2)",
};

export function palette(dark) {
  return dark ? DARK : LIGHT;
}

export function editorTheme(dark, opts = {}) {
  const c = palette(dark);
  const bg = opts.bg || c.bg;
  return EditorView.theme({
    "&": { color: c.fg, backgroundColor: bg, height: "100%", fontSize: (opts.fontSize || 13) + "px" },
    ".cm-scroller": {
      fontFamily: opts.font || 'ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace',
      lineHeight: "1.55",
    },
    ".cm-content": { caretColor: c.cursor, padding: "6px 0 40vh 0" },
    ".cm-cursor, .cm-dropCursor": { borderLeftColor: c.cursor, borderLeftWidth: "2px" },
    "&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground, .cm-selectionBackground, .cm-content ::selection":
      { backgroundColor: c.selection + " !important" },
    "&:not(.cm-focused) > .cm-scroller > .cm-selectionLayer .cm-selectionBackground": { backgroundColor: c.selectionBlur + " !important" },
    ".cm-activeLine": { backgroundColor: c.activeLine },
    ".cm-gutters": { backgroundColor: bg, color: c.gutter, border: "none", paddingLeft: "4px" },
    ".cm-activeLineGutter": { backgroundColor: "transparent", color: c.gutterActive },
    ".cm-lineNumbers .cm-gutterElement": { padding: "0 10px 0 8px", minWidth: "28px" },
    ".cm-foldGutter .cm-gutterElement": { color: c.fold, opacity: "0.55", padding: "0 3px", cursor: "pointer" },
    ".cm-foldPlaceholder": { backgroundColor: "transparent", border: "1px solid " + c.panelBorder, color: c.gutter, borderRadius: "3px", padding: "0 4px" },
    ".cm-matchingBracket": { backgroundColor: c.bracket, outline: "1px solid " + c.bracketBorder, borderRadius: "1px" },
    ".cm-nonmatchingBracket": { color: "#F44747" },
    ".cm-searchMatch": { backgroundColor: c.match, borderRadius: "1px" },
    ".cm-searchMatch.cm-searchMatch-selected": { backgroundColor: c.matchSelected, outline: "1px solid " + c.accent },
    ".cm-selectionMatch": { backgroundColor: dark ? "rgba(173,214,255,0.12)" : "rgba(173,214,255,0.5)" },
    ".cm-highlightSpace": { backgroundImage: "radial-gradient(circle at 50% 55%, " + c.whitespace + " 15%, transparent 5%)" },
    ".cm-panels": { backgroundColor: c.panel, color: c.fg, borderColor: c.panelBorder },
    ".cm-panels.cm-panels-top": { borderBottom: "1px solid " + c.panelBorder },
    ".cm-panel.cm-search": { padding: "8px 10px", fontFamily: "-apple-system, system-ui, sans-serif", fontSize: "13px" },
    ".cm-panel.cm-search input, .cm-panel.cm-gotoLine input": {
      background: c.input, color: c.fg, border: "1px solid " + c.inputBorder, borderRadius: "4px", padding: "4px 6px", fontSize: "13px", outline: "none",
    },
    ".cm-panel.cm-search input:focus": { borderColor: c.accent },
    ".cm-panel.cm-search button, .cm-panel.cm-gotoLine button": {
      background: c.input, color: c.fg, border: "1px solid " + c.inputBorder, borderRadius: "4px", padding: "3px 8px", backgroundImage: "none",
    },
    ".cm-panel.cm-search label": { fontSize: "12px", color: c.gutter },
    ".cm-panel.cm-search [name=close]": { color: c.gutter, fontSize: "18px", border: "none", background: "transparent" },
    ".cm-tooltip": { backgroundColor: c.tooltip, border: "1px solid " + c.panelBorder, borderRadius: "6px", color: c.fg,
      boxShadow: dark ? "0 4px 16px rgba(0,0,0,0.5)" : "0 4px 16px rgba(0,0,0,0.12)" },
    ".cm-tooltip-autocomplete > ul > li": { padding: "2px 8px", fontFamily: "inherit" },
    ".cm-tooltip-autocomplete > ul > li[aria-selected]": { backgroundColor: dark ? "#04395E" : "#E8E8E8", color: c.fg },
    ".cm-completionIcon": { opacity: "0.7" },
    ".cm-completionMatchedText": { textDecoration: "none", color: dark ? "#2AAAFF" : "#0066BF", fontWeight: "600" },
    // 并排 / 合并对比（diff 编辑器）
    ".cm-changedLine, .cm-insertedLine": { backgroundColor: c.inserted + " !important" },
    ".cm-deletedChunk, .cm-deletedLine": { backgroundColor: c.deleted + " !important" },
    ".cm-changedText, .cm-insertedText": { background: c.insertedText + " !important" },
    ".cm-deletedText, .cm-deletedChunk .cm-deletedText": { background: c.deletedText + " !important" },
    "&.cm-merge-a .cm-changedLine, .cm-merge-a .cm-changedLine": { backgroundColor: c.deleted + " !important" },
    "&.cm-merge-a .cm-changedText, .cm-merge-a .cm-changedText": { background: c.deletedText + " !important" },
    ".cm-collapsedLines": { backgroundColor: c.panel, color: c.gutter, fontSize: "12px", padding: "3px 10px",
      fontFamily: "-apple-system, system-ui, sans-serif", backgroundImage: "none", borderTop: "1px solid " + c.panelBorder,
      borderBottom: "1px solid " + c.panelBorder },
    ".cm-changeGutter": { width: "3px", paddingLeft: "0" },
    // 改动标记（和 VS Code 一样在行号右边画竖条）
    ".kl-git-gutter": { width: "4px" },
    ".kl-git-gutter .cm-gutterElement": { padding: "0" },
    ".kl-git-add": { borderLeft: "3px solid " + c.gitAdd, height: "100%" },
    ".kl-git-mod": { borderLeft: "3px solid " + c.gitMod, height: "100%" },
    ".kl-git-del": { height: "100%", position: "relative" },
    ".kl-git-del::after": { content: '""', position: "absolute", left: "0", bottom: "-4px", borderLeft: "5px solid " + c.gitDel,
      borderTop: "4px solid transparent", borderBottom: "4px solid transparent" },
    ".cm-minimap-gutter": { borderLeft: "1px solid " + c.panelBorder },
  }, { dark });
}

export function highlightStyle(dark) {
  const k = dark
    ? { kw: "#569CD6", ctrl: "#C586C0", str: "#CE9178", num: "#B5CEA8", com: "#6A9955", fn: "#DCDCAA", type: "#4EC9B0", vari: "#9CDCFE",
      prop: "#9CDCFE", re: "#D16969", esc: "#D7BA7D", tag: "#569CD6", attr: "#9CDCFE", attrv: "#CE9178", punct: "#D4D4D4", angle: "#808080",
      head: "#569CD6", link: "#4E94CE", con: "#4FC1FF", meta: "#C586C0", inv: "#F44747", ins: "#B5CEA8", del: "#CE9178", lbl: "#C8C8C8", deco: "#DCDCAA" }
    : { kw: "#0000FF", ctrl: "#AF00DB", str: "#A31515", num: "#098658", com: "#008000", fn: "#795E26", type: "#267F99", vari: "#001080",
      prop: "#001080", re: "#811F3F", esc: "#EE0000", tag: "#800000", attr: "#E50000", attrv: "#0000FF", punct: "#3B3B3B", angle: "#800000",
      head: "#800000", link: "#0451A5", con: "#0070C1", meta: "#AF00DB", inv: "#CD3131", ins: "#098658", del: "#A31515", lbl: "#000000", deco: "#795E26" };
  return HighlightStyle.define([
    { tag: [t.keyword, t.modifier, t.operatorKeyword, t.definitionKeyword, t.moduleKeyword, t.self], color: k.kw },
    { tag: [t.controlKeyword], color: k.ctrl },
    { tag: [t.atom, t.bool, t.null], color: k.kw },
    { tag: [t.number, t.integer, t.float], color: k.num },
    { tag: [t.string, t.special(t.string), t.character, t.docString], color: k.str },
    { tag: [t.regexp], color: k.re },
    { tag: [t.escape], color: k.esc },
    { tag: [t.comment, t.lineComment, t.blockComment, t.docComment], color: k.com },
    { tag: [t.variableName, t.definition(t.variableName), t.local(t.variableName)], color: k.vari },
    { tag: [t.function(t.variableName), t.function(t.propertyName), t.function(t.definition(t.variableName))], color: k.fn },
    { tag: [t.propertyName, t.definition(t.propertyName)], color: k.prop },
    { tag: [t.typeName, t.className, t.namespace, t.definition(t.typeName), t.standard(t.typeName)], color: k.type },
    { tag: [t.constant(t.variableName), t.standard(t.variableName), t.special(t.variableName)], color: k.con },
    { tag: [t.macroName], color: k.meta },
    { tag: [t.tagName], color: k.tag },
    { tag: [t.attributeName], color: k.attr },
    { tag: [t.attributeValue], color: k.attrv },
    { tag: [t.angleBracket], color: k.angle },
    { tag: [t.operator, t.punctuation, t.bracket, t.separator, t.derefOperator], color: k.punct },
    { tag: [t.meta, t.processingInstruction, t.documentMeta], color: k.meta },
    { tag: [t.annotation], color: k.deco },
    { tag: [t.labelName], color: k.lbl },
    { tag: [t.heading, t.heading1, t.heading2, t.heading3], color: k.head, fontWeight: "bold" },
    { tag: [t.emphasis], fontStyle: "italic" },
    { tag: [t.strong], fontWeight: "bold" },
    { tag: [t.strikethrough], textDecoration: "line-through" },
    { tag: [t.link, t.url], color: k.link, textDecoration: "underline" },
    { tag: [t.monospace], color: k.str },
    { tag: [t.quote], color: k.com },
    { tag: [t.list], color: k.kw },
    { tag: [t.inserted], color: k.ins },
    { tag: [t.deleted], color: k.del },
    { tag: [t.changed], color: k.kw },
    { tag: [t.invalid], color: k.inv },
  ]);
}
