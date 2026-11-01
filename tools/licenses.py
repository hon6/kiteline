#!/usr/bin/env python3
"""第三方开源组件的许可声明：各端「设置 → 关于 → 开源许可」都读这里生成的清单。

  python3 tools/licenses.py rust               点对点模块 p2p/ 的 Rust 依赖（要 cargo，在 Mac 上跑）→ tools/licenses/rust.json
  python3 tools/licenses.py python <python>    电脑端打包进去的 Python 包：用装了 desktop/requirements.lock 的那个 Python 读
                                               → tools/licenses/python.json
  python3 tools/licenses.py nuget [obj 目录]    Windows / Linux 客户端的 NuGet 包（客户端编过一次才有 obj/project.assets.json，
                                               包在 ~/.nuget/packages）→ tools/licenses/nuget.json
  python3 tools/licenses.py npm [node_modules]  代码 IDE 编辑器内核（tools/editor，CodeMirror）打进去的 npm 包：读 package-lock.json
                                               和装好的 node_modules（tools/editor/build.sh 装在 ~/.cache/kl-editor）→ tools/licenses/npm.json
  python3 tools/licenses.py build              合成各端的清单：Resources/ThirdPartyNotices.json（Mac，build.sh 拷进 App）、
                                               KitelineKit/ThirdPartyNotices.json（iPhone，同步文件夹自动打进包）、
                                               desktop/client/Assets/ThirdPartyNotices.json（Windows / Linux 客户端）

不在包管理器里的（语音识别库、图标、模型、Python 本身……）手写在 tools/licenses/manual.json，许可原文放 tools/licenses/texts/。
依赖有增减（Cargo.lock、requirements.lock、csproj 变了）就把那一类重新收集一遍，再 build。
"""
import datetime
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HERE = os.path.join(ROOT, "tools", "licenses")
# 包里算许可原文的文件：LICENSE、LICENSE-MIT、COPYING、NOTICE、THIRD-PARTY-NOTICES……
LICENSE_FILE = re.compile(r"^(licen[cs]e|copying|notice|copyright|unlicense|third[-_]?party[-_]?notices?)([-_. ].*)?$", re.I)
SOURCE_SUFFIX = (".rs", ".py", ".pyi", ".cs", ".toml", ".json", ".html", ".js", ".ts", ".swift", ".c", ".h")

# 点对点库编给哪些平台（p2p/build.sh；电脑端的 Windows dll、Linux so）
RUST_TARGETS = {
    "mac": ["aarch64-apple-darwin", "x86_64-apple-darwin"],
    "ios": ["aarch64-apple-ios"],
    "desktop": ["x86_64-pc-windows-msvc", "x86_64-pc-windows-gnu", "x86_64-unknown-linux-gnu"],
}
# 电脑端打包时另外装的（不在 requirements.lock 里，或只在 Windows 上装）
PYTHON_EXTRA = ["colorama", "tzdata", "pyinstaller"]
# 只在 Mac 上开发电脑端时才装的，不打进 Windows / Linux 包
PYTHON_SKIP = re.compile(r"^pyobjc", re.I)
# NuGet 里不打进发布包的：编译时用的、别的平台（WebAssembly、macOS）的原生库、用不到的 ASP.NET 运行时
NUGET_SKIP = re.compile(r"^(avalonia\.buildservices|avalonia\.native|microsoft\.aspnetcore\..*|.*\.webassembly|.*\.macos)$", re.I)

# 包里写得不规范的许可名称 → 标准写法；nuspec 只给了失效链接的按许可文件定
LICENSE_ALIASES = {"apache 2.0": "Apache-2.0", "apache licensed, as found in the license file": "Apache-2.0", "lgplv3": "LGPL-3.0",
                   "lgplv2+": "LGPL-2.0-or-later", "mit/apache-2.0": "MIT OR Apache-2.0", "apache-2.0 / mit": "Apache-2.0 OR MIT"}
LICENSE_OVERRIDES = {"Avalonia.Angle.Windows.Natives": "BSD-3-Clause"}

OUTPUTS = {
    "mac": "Resources/ThirdPartyNotices.json",
    "ios": "KitelineKit/ThirdPartyNotices.json",
    "desktop": "desktop/client/Assets/ThirdPartyNotices.json",
}

MIT_BODY = """Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE."""


def read(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def save(name, data):
    with open(os.path.join(HERE, name), "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=1, sort_keys=True)
        handle.write("\n")
    print("已写 tools/licenses/%s（%d 项）" % (name, len(data)))


def license_texts(folder, extra=()):
    """包目录（及其中的 licenses/ 子目录）里的许可原文；extra 是清单里点名的许可文件"""
    paths = []
    for base in (folder, os.path.join(folder, "licenses"), os.path.join(folder, "LICENSES")):
        try:
            names = sorted(os.listdir(base))
        except OSError:
            continue
        for name in names:
            path = os.path.join(base, name)
            if os.path.isfile(path) and LICENSE_FILE.match(name) and not name.lower().endswith(SOURCE_SUFFIX):
                paths.append(path)
    paths += [path for path in extra if path and os.path.isfile(path)]
    out = []
    for path in dict.fromkeys(os.path.realpath(p) for p in paths):
        text = normalize(read(path))
        if text and text not in out:
            out.append(text)
    return out


def normalize(text):
    return "\n".join(line.rstrip() for line in text.replace("\r\n", "\n").replace("\r", "\n").strip("\n﻿").split("\n")).strip()


# --- Rust ---

def collect_rust():
    cargo = shutil.which("cargo") or os.path.expanduser("~/.cargo/bin/cargo")
    found = {}
    for product, triples in RUST_TARGETS.items():
        for triple in triples:
            meta = json.loads(subprocess.check_output([cargo, "metadata", "--format-version", "1", "--locked", "--filter-platform", triple],
                                                      cwd=os.path.join(ROOT, "p2p")))
            packages = {p["id"]: p for p in meta["packages"]}
            nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
            root = meta["resolve"]["root"]
            seen, todo = set(), [root]
            while todo:
                pid = todo.pop()
                if pid in seen:
                    continue
                seen.add(pid)
                # 只算编进程序的普通依赖；build.rs、测试用的不算
                todo += [dep["pkg"] for dep in nodes[pid]["deps"] if any(kind["kind"] is None for kind in dep["dep_kinds"])]
            for pid in seen - {root}:
                package = packages[pid]
                key = "%s@%s" % (package["name"], package["version"])
                if key not in found:
                    folder = os.path.dirname(package["manifest_path"])
                    named = package.get("license_file") and os.path.join(folder, package["license_file"])
                    found[key] = {"name": package["name"], "version": package["version"], "license": package.get("license") or "",
                                  "url": package.get("repository") or package.get("homepage") or "https://crates.io/crates/" + package["name"],
                                  "authors": package.get("authors") or [], "texts": license_texts(folder, [named]), "products": []}
                if product not in found[key]["products"]:
                    found[key]["products"].append(product)
    save("rust.json", sorted(found.values(), key=lambda r: (r["name"].lower(), r["version"])))


# --- Python ---

PY_DUMP = r"""
import importlib.metadata as m, json, os, sys
out = []
for dist in m.distributions():
    md = dist.metadata
    files = [str(dist.locate_file(f)) for f in (dist.files or [])]
    urls = [u.split(",", 1)[-1].strip() for u in (md.get_all("Project-URL") or [])]
    out.append({"name": md["Name"], "version": md["Version"], "expression": md.get("License-Expression") or "",
                "license": md.get("License") or "", "classifiers": [c for c in (md.get_all("Classifier") or []) if c.startswith("License ::")],
                "url": md.get("Home-page") or (urls[0] if urls else ""), "authors": md.get("Author") or md.get("Author-email") or "",
                "files": files, "declared": md.get_all("License-File") or []})
json.dump(out, sys.stdout)
"""

CLASSIFIER_SPDX = {"MIT License": "MIT", "Apache Software License": "Apache-2.0", "BSD License": "BSD", "ISC License (ISCL)": "ISC",
                   "Python Software Foundation License": "PSF-2.0", "Mozilla Public License 2.0 (MPL 2.0)": "MPL-2.0",
                   "GNU Lesser General Public License v3 (LGPLv3)": "LGPL-3.0",
                   "GNU Lesser General Public License v3 or later (LGPLv3+)": "LGPL-3.0-or-later",
                   "GNU Lesser General Public License v2 or later (LGPLv2+)": "LGPL-2.0-or-later",
                   "GNU General Public License v2 (GPLv2)": "GPL-2.0", "GNU General Public License v3 (GPLv3)": "GPL-3.0"}


def python_license(dist):
    if dist["expression"]:
        return dist["expression"]
    text = dist["license"].strip()
    if text and len(text) < 80 and "\n" not in text and text.upper() != "UNKNOWN":
        return text
    names = [CLASSIFIER_SPDX.get(c.split(" :: ")[-1], c.split(" :: ")[-1]) for c in dist["classifiers"]]
    return " OR ".join(dict.fromkeys(names))


def collect_python(python):
    lock = read(os.path.join(ROOT, "desktop", "requirements.lock"))
    wanted = {re.split(r"[=<>; ]", line.strip())[0].lower().replace("_", "-")
              for line in lock.splitlines() if line.strip() and not line.lstrip().startswith(("#", "--"))}
    wanted |= set(PYTHON_EXTRA)
    dists = json.loads(subprocess.check_output([python, "-I", "-c", PY_DUMP]))
    found = []
    for dist in dists:
        name = dist["name"].lower().replace("_", "-")
        if name not in wanted or PYTHON_SKIP.match(name):
            continue
        # dist-info / egg-info 里的许可文件（metadata 的 License-File 点名的优先）
        info_dirs = {os.path.dirname(f) for f in dist["files"] if re.search(r"\.(dist|egg)-info[/\\]METADATA$", f)}
        paths = [f for f in dist["files"] if LICENSE_FILE.match(os.path.basename(f)) and not f.lower().endswith(SOURCE_SUFFIX)
                 and (any(f.startswith(d) for d in info_dirs) or os.path.basename(f) in dist["declared"])]
        texts = []
        for path in paths:
            if os.path.isfile(path):
                text = normalize(read(path))
                if text and text not in texts:
                    texts.append(text)
        if not texts and len(dist["license"]) >= 80:   # 许可全文直接写在 metadata 的 License 里的
            texts.append(normalize(dist["license"]))
        found.append({"name": dist["name"], "version": dist["version"], "license": python_license(dist), "url": dist["url"],
                      "authors": [dist["authors"]] if dist["authors"] else [], "texts": texts, "products": ["desktop"]})
    missing = wanted - {r["name"].lower().replace("_", "-") for r in found} - {w for w in wanted if PYTHON_SKIP.match(w)}
    if missing:
        print("这个 Python 里没装：%s（先装上再收集）" % "、".join(sorted(missing)))
    save("python.json", sorted(found, key=lambda r: r["name"].lower()))


# --- NuGet ---

def collect_nuget(obj=None):
    obj = obj or os.path.join(ROOT, "desktop", "client", "obj")
    assets = json.loads(read(os.path.join(obj, "project.assets.json")))
    store = (assets.get("project", {}).get("restore", {}).get("packagesPath") or os.path.expanduser("~/.nuget/packages"))
    packages = [tuple(key.split("/", 1)) for key, value in assets["libraries"].items() if value.get("type") == "package"]
    # 独立发布（publish.sh --self-contained）带上的 .NET 运行时：取缓存里最新的那版
    for rid in ("win-x64", "linux-x64"):
        versions = sorted(glob.glob(os.path.join(store, "microsoft.netcore.app.runtime." + rid, "*")), key=lambda p: [int(x) if x.isdigit() else x for x in re.split(r"[.-]", os.path.basename(p))])
        if versions:
            packages.append(("Microsoft.NETCore.App.Runtime." + rid, os.path.basename(versions[-1])))
    found = []
    for package_id, version in packages:
        if NUGET_SKIP.match(package_id):
            continue
        folder = os.path.join(store, package_id.lower(), version.lower())
        record = {"name": package_id, "version": version, "license": "", "url": "", "authors": [], "texts": [], "products": ["desktop"]}
        named = []
        nuspec = glob.glob(os.path.join(folder, "*.nuspec"))
        if nuspec:
            meta = {}
            for element in ET.parse(nuspec[0]).getroot().iter():
                tag = element.tag.split("}")[-1]
                if tag in ("license", "licenseUrl", "projectUrl", "copyright", "authors") and tag not in meta:
                    meta[tag] = ((element.text or "").strip(), element.attrib.get("type"))
            license, kind = meta.get("license", ("", None))
            if kind == "file":
                named.append(os.path.join(folder, license))
                license = ""
            record["license"] = license or meta.get("licenseUrl", ("", None))[0]
            record["url"] = meta.get("projectUrl", ("", None))[0]
            record["authors"] = [text for text in (meta.get("copyright", ("", None))[0], meta.get("authors", ("", None))[0]) if text][:1]
        record["texts"] = license_texts(folder, named)
        found.append(record)
    save("nuget.json", sorted(found, key=lambda r: r["name"].lower()))


def collect_npm(modules=None):
    """编辑器内核打包进 HTML 的 npm 包（esbuild 这类只在打包时用的不算），Mac 和 iPhone 都带"""
    modules = modules or os.path.expanduser("~/.cache/kl-editor/node_modules")
    lock = json.loads(read(os.path.join(ROOT, "tools", "editor", "package-lock.json")))
    found = []
    for key, info in sorted(lock.get("packages", {}).items()):
        if not key.startswith("node_modules/") or info.get("dev"):
            continue
        name = key[len("node_modules/"):]
        if name == "esbuild" or name.startswith("@esbuild/"):
            continue
        folder = os.path.join(modules, name)
        meta = {}
        try:
            meta = json.loads(read(os.path.join(folder, "package.json")))
        except OSError:
            pass
        repo = meta.get("repository")
        url = (repo.get("url") if isinstance(repo, dict) else repo) or meta.get("homepage") or ""
        url = re.sub(r"^git\+|\.git$", "", url).replace("git://", "https://")
        found.append({"name": name, "version": info.get("version", ""), "license": info.get("license") or meta.get("license") or "",
                      "url": url, "authors": [], "texts": license_texts(folder), "products": ["mac", "ios"]})
    save("npm.json", found)


# --- 合成 ---

LIST_ITEM = re.compile(r"^(\(?[a-z0-9ivx]{1,4}[.)]\s|[-*•o]\s|#|[=\-_*]{4,})", re.I)


def reflow(text):
    """许可原文大多按 80 列硬换行，窄屏上再折一次就参差不齐：同一段里的硬换行合成一行，交给界面按宽度折。
    只动换行，不动文字；空行（分段）、列表项、缩进变深的行、分隔线，以及跟在短行（标题、署名）后面的行都原样另起"""
    out, last, hanging = [], "", False
    for line in text.split("\n"):
        stripped = line.strip()
        indent = len(line) - len(line.lstrip())
        last_indent = len(last) - len(last.lstrip())
        # 列表项（「(a) …」「4. …」）的续行是悬挂缩进，比项目那行多缩进几格，也算同一段
        if not last.strip():
            hanging = False
        elif LIST_ITEM.match(last.strip()):
            hanging = True
        if (out and stripped and len(last.strip()) >= 50 and indent <= last_indent + (6 if hanging else 2)
                and not LIST_ITEM.match(stripped) and not re.fullmatch(r"[=\-_*~ ]+", stripped)):
            out[-1] = out[-1].rstrip() + " " + stripped
        else:
            out.append(line)
        last = line
    return "\n".join(out)


def fallback(record, standard):
    """包里没带许可文件的：MIT 按标准条文补上版权人，Apache-2.0 用标准全文，其余写明许可和出处"""
    terms = record["license"]
    owners = ", ".join(a for a in record.get("authors") or [] if a) or record["name"] + " authors"
    if re.search(r"\bMIT\b", terms):
        return "MIT License\n\nCopyright (c) %s\n\n%s" % (owners, MIT_BODY)
    if "Apache-2.0" in terms and "apache" in standard:
        return standard["apache"]
    return "License: %s\nCopyright: %s\nSource: %s" % (terms or "see source", owners, record.get("url") or "")


def license_name(record):
    if record["name"] in LICENSE_OVERRIDES:
        return LICENSE_OVERRIDES[record["name"]]
    text = record["license"].strip()
    return "" if text.lower().startswith("http") else LICENSE_ALIASES.get(text.lower(), text)


def build():
    records = []
    for kind in ("rust", "python", "nuget", "npm"):
        path = os.path.join(HERE, kind + ".json")
        if os.path.exists(path):
            records += json.loads(read(path))
        else:
            print("还没收集 %s（tools/licenses/%s.json），这一类先空着" % (kind, kind))
    for item in json.loads(read(os.path.join(HERE, "manual.json"))):
        item = dict(item)
        item["texts"] = [normalize(read(os.path.join(HERE, "texts", name))) for name in item.pop("files", [])]
        records.append(item)
    standard = {"apache": normalize(read(os.path.join(HERE, "texts", "apache-2.0.txt")))}
    stamp = datetime.date.today().isoformat()
    for product, target in OUTPUTS.items():
        texts, index, rows = [], {}, []
        for record in sorted((r for r in records if product in r["products"]), key=lambda r: (r["name"].lower(), r["version"])):
            refs = []
            for text in record["texts"] or [fallback(record, standard)]:
                text = reflow(text)
                if text not in index:
                    index[text] = len(texts)
                    texts.append(text)
                refs.append(index[text])
            row = {"name": record["name"], "version": record["version"], "license": license_name(record), "url": record.get("url") or "", "texts": refs}
            if record.get("note"):
                row["note"] = record["note"]
            rows.append(row)
        with open(os.path.join(ROOT, target), "w", encoding="utf-8") as handle:
            json.dump({"generated": stamp, "components": rows, "texts": texts}, handle, ensure_ascii=False, separators=(",", ":"))
        print("%s：%d 个组件、%d 份许可原文 → %s（%d KB）" % (product, len(rows), len(texts), target, os.path.getsize(os.path.join(ROOT, target)) // 1024))


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "rust":
        collect_rust()
    elif command == "python" and len(sys.argv) > 2:
        collect_python(sys.argv[2])
    elif command == "nuget":
        collect_nuget(sys.argv[2] if len(sys.argv) > 2 else None)
    elif command == "npm":
        collect_npm(sys.argv[2] if len(sys.argv) > 2 else None)
    elif command == "build":
        build()
    else:
        print(__doc__)
        sys.exit(1)
