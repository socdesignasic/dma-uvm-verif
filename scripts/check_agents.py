#!/usr/bin/env python3
"""
check_agents.py - 서브에이전트(.claude/agents/*.md)와 스킬(.claude/skills/*/SKILL.md) 정의를 검사합니다.

  python scripts/check_agents.py       # 문제가 있으면 종료 코드 1

검사 (문제 코드):
  AGENT_META     frontmatter에 name/description/tools가 없거나, name이 파일 이름과 다름
  AGENT_TOOL     없는 도구 이름 (vivado MCP는 server.py에서, Jenkins MCP는 아래 목록에서 확인)
  AGENT_WRITE    검토하는 쪽 에이전트(파일을 고치지 않는 역할)에 Edit/Write 도구가 있음
  AGENT_PATH     프롬프트에 폴더 이동(TB 0-1단계)으로 바뀔 verif/ 아래 경로를 박아 둠 (문서를 읽게 할 것)
  SKILL_META     SKILL.md frontmatter에 name/description이 없거나, name이 폴더 이름과 다름
  STALE_REF      에이전트, 스킬, 문서가 없는 에이전트나 스킬을 가리킴 (docs/REPORT.md는 고정 기록이라 제외)
"""
from __future__ import annotations

import ast
import re
import subprocess
import sys
from pathlib import Path

from common import ROOT, setup_utf8

setup_utf8()

BUILTIN = {"Read", "Grep", "Glob", "Edit", "Write", "Bash", "NotebookEdit", "WebFetch", "WebSearch"}
# 이 PC의 Jenkins MCP(mcp-server 플러그인)가 제공하는 도구 (2026-11-20 세션에서 확인한 목록)
JENKINS = {"cancelBuild", "findJobsWithScmUrl", "getBuild", "getBuildChangeSets", "getBuildLog", "getBuildScm",
           "getFlakyFailures", "getJob", "getJobScm", "getJobs", "getLogRecorders", "getQueueItem",
           "getReplayScripts", "getStatus", "getSystemLog", "getTestResults", "rebuildBuild", "searchBuildLog",
           "triggerBuild", "updateBuild", "whoAmI"}
WRITERS = {"verif-planner", "uvm-builder", "doc-sync"}      # 파일을 고쳐도 되는 에이전트
ROLE = re.compile(r"(?<![A-Za-z0-9_-])[a-z]+-(?:planner|builder|reviewer|triage|watcher|closer|sync)"
                  r"(?![A-Za-z0-9_-])")                     # 에이전트 이름처럼 보이는 말 (한국어 조사가 바로 붙어도 잡음)
MOVING = re.compile(r"verif/(?:agents|env|sequences|tests|tb|filelist)/")  # 0-1단계에서 옮겨질 경로
DOC_EXCLUDE = ("uvm_reference/", "SW/", "out/", "docs/REPORT.md")


def frontmatter(text: str) -> dict[str, str]:
    m = re.match(r"---\n(.*?)\n---\n", text, re.S)
    if not m:
        return {}
    out = {}
    for line in m.group(1).splitlines():
        k, _, v = line.partition(":")
        if v:
            out[k.strip()] = v.strip()
    return out


def vivado_tools() -> set[str]:
    src = (ROOT / "mcp" / "vivado_mcp" / "server.py").read_text(encoding="utf-8")
    return {n.name for n in ast.parse(src).body if isinstance(n, ast.FunctionDef)
            and any("tool" in ast.unparse(d) for d in n.decorator_list)}


def check(root: Path = ROOT) -> list[str]:
    probs = []
    agents = {p.stem: p for p in sorted((root / ".claude" / "agents").glob("*.md"))}
    skills = {p.parent.name: p for p in sorted((root / ".claude" / "skills").glob("*/SKILL.md"))}
    viv = vivado_tools()
    for name, p in agents.items():
        txt = p.read_text(encoding="utf-8")
        fm = frontmatter(txt)
        for k in ("name", "description", "tools"):
            if not fm.get(k):
                probs.append(f"AGENT_META {name}: missing '{k}'")
        if fm.get("name") and fm["name"] != name:
            probs.append(f"AGENT_META {name}: name '{fm['name']}' differs from the file name")
        for k, v in fm.items():                             # YAML 평문 값에 ": "가 있으면 정의가 통째로 무시됨
            if ": " in v:
                probs.append(f"AGENT_META {name}: '{k}' value contains ': ' (breaks YAML, the agent is not loaded)")
        tools = [t.strip() for t in fm.get("tools", "").split(",") if t.strip()]
        for t in tools:
            ok = (t in BUILTIN or (t.startswith("mcp__vivado__") and t[13:] in viv)
                  or (t.startswith("mcp__jenkins__") and t[14:] in JENKINS) or t.startswith("mcp__github__"))
            if not ok:
                probs.append(f"AGENT_TOOL {name}: unknown tool {t}")
        if name not in WRITERS and {"Edit", "Write", "NotebookEdit"} & set(tools):
            probs.append(f"AGENT_WRITE {name}: a reviewing agent must not have Edit/Write")
        body = txt.split("---", 2)[-1]
        for m in sorted(set(MOVING.findall(body))):
            probs.append(f"AGENT_PATH {name}: hard-coded path {m} (point to CLAUDE.md / docs/UVM_STRUCTURE.md instead)")
    for name, p in skills.items():
        fm = frontmatter(p.read_text(encoding="utf-8"))
        for k in ("name", "description"):
            if not fm.get(k):
                probs.append(f"SKILL_META {name}: missing '{k}'")
        if fm.get("name") and fm["name"] != name:
            probs.append(f"SKILL_META {name}: name '{fm['name']}' differs from the folder name")
        for k, v in fm.items():
            if ": " in v:
                probs.append(f"SKILL_META {name}: '{k}' value contains ': ' (breaks YAML, the skill description is lost)")
    r = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard", "*.md"], cwd=root,
                       capture_output=True, text=True, encoding="utf-8")
    texts = [root / f for f in r.stdout.split() if not f.startswith(DOC_EXCLUDE) and (root / f).exists()]
    for p in texts:                                         # 없는 에이전트/스킬을 가리키는 곳
        txt = p.read_text(encoding="utf-8")
        rel = p.relative_to(root).as_posix()
        for tok in sorted(set(ROLE.findall(txt))):
            if tok not in agents:
                probs.append(f"STALE_REF {rel}: agent '{tok}' does not exist")
        for tok in sorted(set(re.findall(r"`/([a-z]+(?:-[a-z]+)+)`", txt))):  # `/스킬 이름`
            if tok not in skills:
                probs.append(f"STALE_REF {rel}: skill '/{tok}' does not exist")
    return probs


def main() -> int:
    probs = check()
    for p in probs:
        print(p)
    n_a = len(list((ROOT / ".claude" / "agents").glob("*.md")))
    n_s = len(list((ROOT / ".claude" / "skills").glob("*/SKILL.md")))
    print(f"check agents: {n_a} agents, {n_s} skills -> {'OK' if not probs else 'FAIL'}")
    return 0 if not probs else 1


if __name__ == "__main__":
    sys.exit(main())
