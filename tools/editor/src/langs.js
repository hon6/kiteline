// 按文件名认语言：常用的用 Lezer 语法（结构化，能折叠、补全），其余用 legacy 模式（只着色）
import { LanguageSupport, StreamLanguage } from "@codemirror/language";
import { javascript } from "@codemirror/lang-javascript";
import { python } from "@codemirror/lang-python";
import { html } from "@codemirror/lang-html";
import { css } from "@codemirror/lang-css";
import { sass } from "@codemirror/lang-sass";
import { less } from "@codemirror/lang-less";
import { json } from "@codemirror/lang-json";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { xml } from "@codemirror/lang-xml";
import { yaml } from "@codemirror/lang-yaml";
import { sql } from "@codemirror/lang-sql";
import { rust } from "@codemirror/lang-rust";
import { cpp } from "@codemirror/lang-cpp";
import { java } from "@codemirror/lang-java";
import { php } from "@codemirror/lang-php";
import { go } from "@codemirror/lang-go";
import { vue } from "@codemirror/lang-vue";
import { swift } from "@codemirror/legacy-modes/mode/swift";
import { shell } from "@codemirror/legacy-modes/mode/shell";
import { ruby } from "@codemirror/legacy-modes/mode/ruby";
import { toml } from "@codemirror/legacy-modes/mode/toml";
import { dockerFile } from "@codemirror/legacy-modes/mode/dockerfile";
import { lua } from "@codemirror/legacy-modes/mode/lua";
import { kotlin, csharp, objectiveC, scala, dart } from "@codemirror/legacy-modes/mode/clike";
import { perl } from "@codemirror/legacy-modes/mode/perl";
import { r } from "@codemirror/legacy-modes/mode/r";
import { powerShell } from "@codemirror/legacy-modes/mode/powershell";
import { diff } from "@codemirror/legacy-modes/mode/diff";
import { properties } from "@codemirror/legacy-modes/mode/properties";
import { nginx } from "@codemirror/legacy-modes/mode/nginx";
import { cmake } from "@codemirror/legacy-modes/mode/cmake";
import { protobuf } from "@codemirror/legacy-modes/mode/protobuf";
import { groovy } from "@codemirror/legacy-modes/mode/groovy";
import { haskell } from "@codemirror/legacy-modes/mode/haskell";
import { clojure } from "@codemirror/legacy-modes/mode/clojure";
import { erlang } from "@codemirror/legacy-modes/mode/erlang";
import { julia } from "@codemirror/legacy-modes/mode/julia";
import { commonLisp } from "@codemirror/legacy-modes/mode/commonlisp";
import { elm } from "@codemirror/legacy-modes/mode/elm";
import { fortran } from "@codemirror/legacy-modes/mode/fortran";
import { verilog } from "@codemirror/legacy-modes/mode/verilog";
import { vhdl } from "@codemirror/legacy-modes/mode/vhdl";
import { tcl } from "@codemirror/legacy-modes/mode/tcl";
import { pascal } from "@codemirror/legacy-modes/mode/pascal";
import { stylus } from "@codemirror/legacy-modes/mode/stylus";
import { coffeeScript } from "@codemirror/legacy-modes/mode/coffeescript";

const legacy = (mode) => () => new LanguageSupport(StreamLanguage.define(mode));

// [显示名, 工厂, 扩展名, 整个文件名]
const TABLE = [
  ["JavaScript", () => javascript(), ["js", "mjs", "cjs"]],
  ["JavaScript JSX", () => javascript({ jsx: true }), ["jsx"]],
  ["TypeScript", () => javascript({ typescript: true }), ["ts", "mts", "cts"]],
  ["TypeScript JSX", () => javascript({ typescript: true, jsx: true }), ["tsx"]],
  ["JSON", () => json(), ["json", "jsonc", "json5", "webmanifest", "jsonl", "ndjson", "har", "ipynb"], [".babelrc", ".eslintrc", ".prettierrc", "composer.lock"]],
  ["Python", () => python(), ["py", "pyw", "pyi", "pyx", "gyp"], ["SConstruct", "SConscript"]],
  ["HTML", () => html(), ["html", "htm", "xhtml", "shtml", "ejs", "hbs", "njk", "liquid", "jinja", "j2", "erb"]],
  ["Vue", () => vue(), ["vue"]],
  ["CSS", () => css(), ["css", "pcss", "postcss"]],
  ["SCSS", () => sass({ indented: false }), ["scss"]],
  ["Sass", () => sass({ indented: true }), ["sass"]],
  ["Less", () => less(), ["less"]],
  ["Stylus", legacy(stylus), ["styl"]],
  ["Markdown", () => markdown({ base: markdownLanguage, codeLanguages: (info) => fenced(info) }), ["md", "markdown", "mdx", "mdown", "mkd"]],
  ["XML", () => xml(), ["xml", "plist", "svg", "xaml", "axaml", "csproj", "vbproj", "fsproj", "props", "targets", "xsd", "xsl", "xslt",
    "storyboard", "xib", "entitlements", "resx", "nuspec", "rss", "atom", "wsdl", "xcscheme", "xcworkspacedata", "manifest", "pom"]],
  ["YAML", () => yaml(), ["yml", "yaml"], [".clang-format", ".clangd"]],
  ["SQL", () => sql(), ["sql", "psql", "mysql"]],
  ["Rust", () => rust(), ["rs"]],
  ["C", () => cpp(), ["c", "h"]],
  ["C++", () => cpp(), ["cpp", "cc", "cxx", "c++", "hpp", "hh", "hxx", "h++", "ino", "cu", "cuh", "metal", "glsl", "hlsl", "frag", "vert"]],
  ["Objective-C", legacy(objectiveC), ["m", "mm"]],
  ["Java", () => java(), ["java", "jav"]],
  ["Kotlin", legacy(kotlin), ["kt", "kts"]],
  ["C#", legacy(csharp), ["cs", "csx", "cake"]],
  ["Scala", legacy(scala), ["scala", "sc", "sbt"]],
  ["Dart", legacy(dart), ["dart"]],
  ["PHP", () => php(), ["php", "phtml", "php3", "php4", "php5", "phps"]],
  ["Go", () => go(), ["go"]],
  ["Swift", legacy(swift), ["swift"]],
  ["Shell", legacy(shell), ["sh", "bash", "zsh", "ksh", "fish", "command", "bats", "envrc"],
    [".bashrc", ".bash_profile", ".zshrc", ".zprofile", ".profile", "Makefile", "makefile", "GNUmakefile", "PKGBUILD", ".envrc"]],
  ["Ruby", legacy(ruby), ["rb", "rake", "gemspec", "podspec", "ru", "rbw"], ["Gemfile", "Rakefile", "Podfile", "Fastfile", "Appfile", "Brewfile", "Vagrantfile", "Guardfile"]],
  ["TOML", legacy(toml), ["toml"], ["Cargo.lock", "Pipfile", "poetry.lock", "uv.lock"]],
  ["Dockerfile", legacy(dockerFile), ["dockerfile", "containerfile"], ["Dockerfile", "Containerfile"]],
  ["Lua", legacy(lua), ["lua"]],
  ["Perl", legacy(perl), ["pl", "pm", "t", "pod"]],
  ["R", legacy(r), ["r", "rmd"]],
  ["PowerShell", legacy(powerShell), ["ps1", "psm1", "psd1"]],
  ["Diff", legacy(diff), ["diff", "patch", "rej"]],
  ["Properties", legacy(properties), ["properties", "ini", "cfg", "conf", "env", "editorconfig", "gitconfig", "gitmodules", "npmrc", "desktop", "service", "inf", "reg"],
    [".gitignore", ".gitattributes", ".dockerignore", ".npmignore", ".env", ".editorconfig", ".gitconfig", ".gitmodules", ".npmrc", ".flake8", ".pylintrc", "CODEOWNERS"]],
  ["Nginx", legacy(nginx), ["nginx"], ["nginx.conf"]],
  ["CMake", legacy(cmake), ["cmake"], ["CMakeLists.txt"]],
  ["Protocol Buffers", legacy(protobuf), ["proto"]],
  ["Groovy", legacy(groovy), ["groovy", "gradle", "gvy"], ["Jenkinsfile"]],
  ["Haskell", legacy(haskell), ["hs", "lhs"]],
  ["Clojure", legacy(clojure), ["clj", "cljs", "cljc", "edn"]],
  ["Erlang", legacy(erlang), ["erl", "hrl"]],
  ["Julia", legacy(julia), ["jl"]],
  ["Lisp", legacy(commonLisp), ["lisp", "lsp", "el", "cl", "scm", "ss"]],
  ["Elm", legacy(elm), ["elm"]],
  ["Fortran", legacy(fortran), ["f", "for", "f90", "f95", "f03"]],
  ["Verilog", legacy(verilog), ["v", "sv", "svh", "vh"]],
  ["VHDL", legacy(vhdl), ["vhd", "vhdl"]],
  ["Tcl", legacy(tcl), ["tcl"]],
  ["Pascal", legacy(pascal), ["pas", "pp", "dpr"]],
  ["CoffeeScript", legacy(coffeeScript), ["coffee"]],
];

const byExt = new Map();
const byName = new Map();
for (const [label, make, exts, names] of TABLE) {
  const entry = { label, make };
  for (const ext of exts) byExt.set(ext, entry);
  for (const name of names || []) byName.set(name, entry);
}

/** 文件名 → { label, support }；认不出的给纯文本 */
export function languageFor(path) {
  const name = (path || "").split("/").pop();
  let entry = byName.get(name);
  if (!entry) {
    const lower = name.toLowerCase();
    const dot = lower.lastIndexOf(".");
    if (dot >= 0) entry = byExt.get(lower.slice(dot + 1));
    if (!entry && lower.startsWith("dockerfile")) entry = byName.get("Dockerfile");
    if (!entry && /^\.env(\.|$)/.test(lower)) entry = byName.get(".env");
  }
  if (!entry) return { label: "Plain Text", support: null };
  try {
    return { label: entry.label, support: entry.make() };
  } catch (e) {
    return { label: "Plain Text", support: null };
  }
}

/** Markdown 代码块 ```lang 里的着色 */
function fenced(info) {
  const word = (info || "").trim().split(/\s/)[0].toLowerCase();
  if (!word) return null;
  const alias = { js: "x.js", javascript: "x.js", ts: "x.ts", typescript: "x.ts", py: "x.py", python: "x.py", sh: "x.sh", bash: "x.sh",
    shell: "x.sh", zsh: "x.sh", console: "x.sh", swift: "x.swift", json: "x.json", yaml: "x.yml", yml: "x.yml", html: "x.html", css: "x.css",
    go: "x.go", rust: "x.rs", rs: "x.rs", java: "x.java", kotlin: "x.kt", c: "x.c", cpp: "x.cpp", "c++": "x.cpp", csharp: "x.cs", cs: "x.cs",
    ruby: "x.rb", rb: "x.rb", php: "x.php", sql: "x.sql", xml: "x.xml", diff: "x.diff", toml: "x.toml", dockerfile: "Dockerfile",
    jsx: "x.jsx", tsx: "x.tsx", vue: "x.vue", scss: "x.scss", lua: "x.lua", powershell: "x.ps1", ps1: "x.ps1", ini: "x.ini" };
  const found = languageFor(alias[word] || "x." + word);
  return found.support ? found.support.language : null;
}
