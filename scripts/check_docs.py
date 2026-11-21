#!/usr/bin/env python3
"""
check_docs.py - 문서가 코드와 맞는지 검사하고, 문서의 생성 구간을 다시 만듭니다.

  python scripts/check_docs.py            # 검사 (문제가 있으면 종료 코드 1)
  python scripts/check_docs.py --write    # 생성 구간을 지금 코드로 다시 만든 뒤 검사

검사 (문제 코드):
  DOC_PATH     `...`로 적은 저장소 경로(scripts/, verif/, docs/, ci/, mcp/, .claude/, HW/, fw/)가 없음
  DOC_CLASS    `...`로 적은 UVM 클래스/패키지/인터페이스 이름이 verif/ 소스에 없음
  DOC_SCRIPT   `python scripts/X.py` 명령의 스크립트가 없음
  DOC_GEN      생성 구간이 지금 코드로 만든 내용과 다름 (--write로 갱신)
  DOC_STAGES   docs/FLOW.md의 CI 단계 표가 Jenkinsfile의 단계와 다름

생성 구간: <!-- gen:NAME --> ... <!-- /gen:NAME -->  (손으로 고치지 않음)
  gen:scripts   scripts/*.py와 첫 줄 설명
  gen:tbs       verif/sim_cfg.json의 TB, 테스트 수, known_fail 수
  gen:mcp_tools mcp/vivado_mcp/server.py의 MCP 도구
"""
from __future__ import annotations                          # 타입 힌트 지연 평가

import argparse                                             # 명령줄 인자
import ast                                                  # 스크립트 docstring, MCP 도구 읽기
import json                                                 # sim_cfg.json
import re                                                   # 문서 파싱
import subprocess                                           # git ls-files
import sys                                                  # 종료 코드
from pathlib import Path                                    # 경로

from common import ROOT, setup_utf8                       # 공통 모듈

setup_utf8()                                                # UTF-8 출력

EXCLUDE = ("uvm_reference/", "SW/", "out/", "mem_copy")  # 검사하지 않는 곳 (외부 참고 자료, 결과물)
RE_PATH = re.compile(r"`((?:\.claude|\.githooks|ci|docs|scripts|verif|mcp|HW|fw)/[^`\s*<>{}|]+)`")  # `경로`
RE_CLASS = re.compile(r"`([a-z][a-z0-9_]*_(?:seq|test|env|agent|scoreboard|coverage|monitor|driver|pkg|cfg|if|"
                      r"model|item|predictor|sequencer|vseq|vsqr|map|base_test))`")  # `클래스 이름`
RE_SCRIPT = re.compile(r"python3?\s+(scripts/[\w./]+\.py)")  # python scripts/X.py
RE_GEN = re.compile(r"(<!-- gen:(\w+) -->\n)(.*?)(<!-- /gen:\2 -->)", re.S)  # 생성 구간


def doc_files() -> list[Path]:                              # 검사할 문서 (git이 추적하는 .md + 새 문서)
    r = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard", "*.md"], cwd=ROOT,
                       capture_output=True, text=True, encoding="utf-8")
    return [ROOT / f for f in r.stdout.split() if not f.startswith(EXCLUDE) and (ROOT / f).exists()]


def first_doc_line(p: Path) -> str:                         # 스크립트 docstring에서 설명 한 줄
    try:
        doc = ast.get_docstring(ast.parse(p.read_text(encoding="utf-8"))) or ""
    except SyntaxError:
        return ""
    for line in doc.splitlines():
        line = line.strip()
        if line and not line.startswith(("python", "#")):
            return re.sub(r"^\S+\.py\s*-\s*", "", line)     # "sim.py - ..." 앞부분 제거
    return ""


def gen_scripts() -> str:
    rows = ["| 스크립트 | 하는 일 |", "|---|---|"]
    for p in sorted((ROOT / "scripts").glob("*.py")):
        rows.append(f"| `scripts/{p.name}` | {first_doc_line(p)} |")
    return "\n".join(rows) + "\n"


def gen_tbs() -> str:
    cfg = json.loads((ROOT / "verif" / "sim_cfg.json").read_text(encoding="utf-8"))
    rows = ["| TB | 설명 | 테스트 | known_fail |", "|---|---|---|---|"]
    n = 0
    for tb, v in cfg["tbs"].items():
        t = len(v.get("tests", []))
        n += t
        rows.append(f"| `{tb}` | {v.get('desc', '').replace('|', chr(92) + '|')} | {t or '-'} | {len(v.get('known_fail') or {}) or '-'} |")
    names = {x for v in cfg["tbs"].values() for x in v.get("tests", [])}
    rows.append(f"\n테스트 {len(names)}종, TB별로 세면 {n}개입니다. CI와 `regress.py`는 이 표의 테스트만 돌립니다.")
    return "\n".join(rows) + "\n"


def gen_mcp_tools() -> str:
    src = (ROOT / "mcp" / "vivado_mcp" / "server.py").read_text(encoding="utf-8")
    rows = ["| 도구 | 하는 일 |", "|---|---|"]
    for node in ast.parse(src).body:
        if isinstance(node, ast.FunctionDef) and any(
                "tool" in ast.unparse(d) for d in node.decorator_list):
            doc = (ast.get_docstring(node) or "").strip().splitlines()
            rows.append(f"| `{node.name}` | {(doc[0] if doc else '').replace('|', chr(92) + '|')} |")
    return "\n".join(rows) + "\n"


GENERATORS = {"scripts": gen_scripts, "tbs": gen_tbs, "mcp_tools": gen_mcp_tools}


def jenkins_stages() -> list[str]:
    return re.findall(r"stage\('([^']+)'\)", (ROOT / "Jenkinsfile").read_text(encoding="utf-8"))


def check(write: bool = False) -> dict:
    probs = []                                              # 문제
    sv = " ".join(p.read_text(encoding="utf-8", errors="ignore")
                  for p in (ROOT / "verif").rglob("*") if p.suffix in (".sv", ".svh"))  # 클래스 이름을 찾을 소스
    for f in doc_files():
        rel = f.relative_to(ROOT).as_posix()
        txt = f.read_text(encoding="utf-8")
        if write:                                           # 생성 구간 갱신
            new = RE_GEN.sub(lambda m: m.group(1) + GENERATORS[m.group(2)]() + m.group(4)
                             if m.group(2) in GENERATORS else m.group(0), txt)
            if new != txt:
                f.write_text(new, encoding="utf-8")
                print(f"updated generated sections in {rel}")
                txt = new
        for m in RE_GEN.finditer(txt):
            g = GENERATORS.get(m.group(2))
            if g is None:
                probs.append(f"DOC_GEN {rel}: unknown generated section gen:{m.group(2)}")
            elif m.group(3) != g():
                probs.append(f"DOC_GEN {rel}: gen:{m.group(2)} is out of date (run: python scripts/check_docs.py --write)")
        body = RE_GEN.sub("", txt)                          # 나머지는 손으로 쓴 부분
        for p in sorted(set(RE_PATH.findall(body))):
            path = p.split(":")[0].rstrip(").,")
            if not (ROOT / path).exists():
                probs.append(f"DOC_PATH {rel}: `{p}` does not exist")
        for c in sorted(set(RE_CLASS.findall(body))):
            if not c.startswith("uvm_") and not re.search(rf"\b{re.escape(c)}\b", sv):
                probs.append(f"DOC_CLASS {rel}: `{c}` not found in verif/ sources")
        for s in sorted(set(RE_SCRIPT.findall(body))):
            if not (ROOT / s).exists():
                probs.append(f"DOC_SCRIPT {rel}: {s} does not exist")
    flow = (ROOT / "docs" / "FLOW.md").read_text(encoding="utf-8")  # CI 단계 표
    sec = flow.split("## 2.", 1)[1].split("\n## ", 1)[0] if "## 2." in flow else ""
    listed = re.findall(r"^\|\s*\w+\s*\|\s*([^|]+?)\s*\|", sec, re.M)
    listed = [s for s in listed if s not in ("단계", "---")]
    if listed != jenkins_stages():
        probs.append(f"DOC_STAGES docs/FLOW.md section 2 lists {listed}, Jenkinsfile has {jenkins_stages()}")
    return {"ok": not probs, "problems": probs}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--write", action="store_true", help="생성 구간을 다시 만든 뒤 검사")
    a = ap.parse_args()
    res = check(a.write)
    for p in res["problems"]:
        print(p)
    print(f"check docs: {len(doc_files())} files -> {'OK' if res['ok'] else 'FAIL'}")
    return 0 if res["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
