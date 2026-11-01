#!/usr/bin/env python3
"""从 KitelineKit/Shared/AgentMark.swift 抽出 agent 表，生成 desktop/client/Model/Agents.g.cs（Mac 版加了 agent 重跑一次）"""
import re, sys, pathlib
repo = pathlib.Path(sys.argv[1])
src = (repo / "KitelineKit/Shared/AgentMark.swift").read_text(encoding="utf-8")
body = src[src.index("public static let all: [AgentInfo] = ["):]
entries = re.findall(r'AgentInfo\(id: "([^"]+)", name: "([^"]+)", layers: \[(.*?)\]\)', body, re.S)
out = ["// 生成的文件：python3 desktop/client/tools/gen-agents.py .（来源 KitelineKit/Shared/AgentMark.swift），别手改", "namespace Kiteline.Model;", "",
       "public static partial class Agents", "{", "    public static readonly AgentInfo[] All =", "    ["]
for id_, name, layers in entries:
    parts = re.findall(r'\("([^"]*)", ([0-9.]+)\)', layers)
    ls = ", ".join(f'new AgentLayer("{d}", {op})' for d, op in parts)
    out.append(f'        new AgentInfo("{id_}", "{name}", [{ls}]),')
out += ["    ];", "}", ""]
(repo / "desktop/client/Model/Agents.g.cs").write_text("\n".join(out), encoding="utf-8")
print(len(entries), "agents")
