// 把编辑器内核打成一个自带脚本和样式的 HTML（不联网也能用）：
//   Resources/editor/code-editor.html   Mac App 打进 Contents/Resources/editor
//   KitelineKit/Editor/code-editor.html    iPhone / iPad（Xcode 同步文件夹会把它摊平到包根，名字不能和别的资源重）
// 用法：bash tools/editor/build.sh（装依赖 + 打包）
import { build } from "esbuild";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = process.env.KL_ROOT || join(here, "..", "..");
const result = await build({
  entryPoints: [join(here, "src", "main.js")],
  bundle: true, minify: true, format: "iife", target: ["safari15"], write: false, legalComments: "none",
});
const js = result.outputFiles[0].text.replace(/<\/script/gi, "<\\/script");
const html = readFileSync(join(here, "src", "index.html"), "utf8").replace("/*KL_SCRIPT*/", () => js);
for (const out of [join(root, "Resources", "editor", "code-editor.html"), join(root, "KitelineKit", "Editor", "code-editor.html")]) {
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, html);
  console.log("→", out, (html.length / 1024).toFixed(0) + " KB");
}
