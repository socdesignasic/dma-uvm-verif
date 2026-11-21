#!/usr/bin/env python3
"""
check_inventory.py - verif/ 아래의 검사 목록을 세고, 기준선과 비교합니다.

  python scripts/check_inventory.py                    # 지금 검사 목록 출력
  python scripts/check_inventory.py --compare          # 기준선과 비교 (줄어든 검사, 늘어난 억제 -> 종료 코드 1)
  python scripts/check_inventory.py --save --reason "..."   # 지금 목록을 기준선으로 저장 (사람이 검토한 뒤에만)
  python scripts/check_inventory.py --json             # JSON으로 출력 (gate.py, MCP용)

세는 것 (ID = 개수):
  - `uvm_error("TAG", ...)`, `uvm_fatal("TAG", ...)`  -> TAG
  - SVA 라벨: `label : assert property`, 그리고 assert property를 만드는 매크로의 호출 -> SVA:label
  - $error(...), $fatal(...)                             -> $error, $fatal
억제 구문 (늘어나면 안 됨):
  report severity/action override, uvm_report_catcher, $assertoff/$assertkill/$assertcontrol, UVM_NO_ACTION

CLAUDE.md 규칙 5(검사를 낮추거나 지우지 않음)를 기계로 확인하는 장치입니다. 검사를 다른 곳으로
옮기면 ID가 같은 한 개수만 맞으면 됩니다. 태그를 바꾸거나 검사를 일부러 없앤 경우에는 사람이
검토하고 --save --reason으로 기준선을 갱신합니다.
기준선: verif/check_baseline.json
"""
from __future__ import annotations                          # 타입 힌트 지연 평가

import argparse                                             # 명령줄 인자
import json                                                 # 기준선 읽기/쓰기
import re                                                   # 소스 파싱
import sys                                                  # 종료 코드
import time                                                 # 저장 시각
from collections import Counter, defaultdict                # 개수, 위치 모음
from pathlib import Path                                    # 경로

from common import ROOT, provenance, setup_utf8           # 공통 모듈

setup_utf8()                                                # UTF-8 출력

VERIF = ROOT / "verif"                                      # 검사 대상 폴더
BASELINE = VERIF / "check_baseline.json"                    # 기준선 파일
EXT = {".sv", ".svh", ".v", ".vh"}                          # SystemVerilog 소스 확장자

RE_UVM = re.compile(r'`uvm_(error|fatal)\s*\(\s*"([A-Za-z0-9_]+)"')  # `uvm_error("TAG"
RE_UVM_DYN = re.compile(r'`uvm_(error|fatal)\s*\(\s*(?!")([^,]+),')  # 태그가 문자열 상수가 아닌 경우
RE_SVA = re.compile(r'^[ \t]*([A-Za-z_]\w*)\s*:\s*(assert|assume)\s+property\b', re.M)  # label : assert property
RE_SYS = re.compile(r'\$(error|fatal)\s*\(')               # $error( / $fatal(
RE_DEFINE = re.compile(r'^\s*`define\s+(\w+)')             # 매크로 정의 시작
SUPPRESS = {                                                # 억제 구문 -> 찾는 정규식
    "report_override": r"\bset_report_severity(_id)?_override\b",
    "report_action": r"\bset_report_(severity_|id_|severity_id_)?action(_hier)?\b",
    "report_catcher": r"\buvm_report_catcher\b",
    "assert_control": r"\$assert(off|kill|control)\b",
    "no_action": r"\bUVM_NO_ACTION\b",
}


def strip_comments(txt: str) -> str:                        # 주석 제거 (줄 번호는 유지)
    txt = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), txt, flags=re.S)  # 블록 주석
    return re.sub(r"//[^\n]*", "", txt)                     # 줄 주석


def split_macros(txt: str) -> tuple[str, dict[str, str]]:   # 매크로 정의를 떼어 냄
    """`define 본문(역슬래시로 이어진 줄)을 지우고 {이름: 본문}으로 돌려줌. 줄 번호는 유지."""
    lines, body, macros, name = txt.split("\n"), [], {}, None  # 줄, 남길 줄, 매크로, 지금 매크로 이름
    for ln in lines:                                        # 줄마다
        m = RE_DEFINE.match(ln)                             # 정의 시작인지
        if name is None and m:                              # 새 정의
            name = m.group(1)                               # 이름
            macros[name] = ln                               # 본문 시작
        elif name is not None:                              # 정의가 이어지는 중
            macros[name] += "\n" + ln                       # 본문에 추가
        else:                                               # 보통 줄
            body.append(ln)                                 # 그대로
            continue                                        # 다음 줄
        body.append("")                                     # 정의 줄은 빈 줄로 (줄 번호 유지)
        if not ln.rstrip().endswith("\\"):                  # 이어지지 않으면 정의 끝
            name = None
    return "\n".join(body), macros                          # 본문, 매크로


def scan(root: Path = VERIF) -> dict:                       # 검사 목록 만들기
    counts, sites, supp = Counter(), defaultdict(list), Counter()  # ID별 개수, 위치, 억제 구문 개수
    files = sorted(p for p in root.rglob("*") if p.suffix in EXT and p.is_file())  # 소스 파일
    texts = {p: strip_comments(p.read_text(encoding="utf-8", errors="replace")) for p in files}  # 주석 뺀 내용
    sva_macros = set()                                      # assert property를 만드는 매크로 이름
    for t in texts.values():                                # 모든 파일의 매크로 정의에서
        for name, body in split_macros(t)[1].items():
            if re.search(r"\b(assert|assume)\s+property\b", body):  # assertion을 만드는 매크로면
                sva_macros.add(name)                        # 기억
    for p, t in texts.items():                              # 파일마다
        base = root.parent if root.name == "verif" else root  # verif/를 검사하면 저장소 기준 경로 (verif/...)
        rel = p.relative_to(base).as_posix()                # 표시용 경로
        body, macros = split_macros(t)                      # 매크로 정의 분리

        def add(cid: str, pos: int, src: str = body):       # 검사 하나 기록
            counts[cid] += 1                                # 개수
            sites[cid].append(f"{rel}:{src.count(chr(10), 0, pos) + 1}")  # 위치 (줄 번호)

        for m in RE_UVM.finditer(t):                        # uvm_error/fatal (매크로 본문 포함, 원본 기준)
            add(m.group(2), m.start(), t)
        for m in RE_UVM_DYN.finditer(t):                    # 태그가 변수인 경우
            add("uvm_" + m.group(1) + "_dynamic", m.start(), t)
        for m in RE_SVA.finditer(body):                     # 직접 쓴 SVA 라벨 (매크로 정의 밖)
            add("SVA:" + m.group(1), m.start())
        for mac in sva_macros:                              # SVA 매크로 호출: `NAME(label, ...)
            for m in re.finditer(r"`" + re.escape(mac) + r"\s*\(\s*(\w+)", body):
                add("SVA:" + m.group(1), m.start())
        for m in RE_SYS.finditer(body):                     # $error / $fatal
            add("$" + m.group(1), m.start())
        for k, rx in SUPPRESS.items():                      # 억제 구문
            n = len(re.findall(rx, body))
            if n:
                supp[k] += n
                sites["suppress:" + k].append(rel)
    return {"checks": dict(sorted(counts.items())), "suppressions": dict(sorted(supp.items())),
            "sites": {k: v for k, v in sorted(sites.items())}, "files": len(files)}


def compare(now: dict, base: dict) -> list[str]:            # 기준선 대비 문제 목록
    problems = []                                           # 문제 줄
    for cid, n in base["checks"].items():                   # 기준선의 검사마다
        got = now["checks"].get(cid, 0)                     # 지금 개수
        if got < n:                                         # 줄었거나 사라졌으면
            where = ", ".join(base.get("sites", {}).get(cid, [])[:4])  # 기준선에서의 위치
            problems.append(f"CHECK_REMOVED {cid}: {n} -> {got} (baseline sites: {where})")
    for k, n in now["suppressions"].items():                # 억제 구문마다
        if n > base.get("suppressions", {}).get(k, 0):      # 늘었으면
            where = ", ".join(now["sites"].get("suppress:" + k, [])[:4])
            problems.append(f"SUPPRESSION_ADDED {k}: {base.get('suppressions', {}).get(k, 0)} -> {n} ({where})")
    return problems                                         # 문제 목록


def main() -> int:                                          # 진입점
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--compare", action="store_true", help="기준선과 비교")
    ap.add_argument("--save", action="store_true", help="지금 목록을 기준선으로 저장")
    ap.add_argument("--reason", help="--save 때 이유 (필수)")
    ap.add_argument("--json", action="store_true", help="JSON 출력")
    ap.add_argument("--root", default=str(VERIF), help="검사할 폴더 (기본: verif/)")
    ap.add_argument("--baseline", default=str(BASELINE), help="기준선 파일")
    a = ap.parse_args()
    now = scan(Path(a.root))                                # 지금 목록
    if a.save:                                              # 기준선 저장
        if not a.reason:
            ap.error("--save needs --reason")               # 이유 없이 저장 금지
        doc = {"updated": time.strftime("%Y-%m-%d %H:%M:%S"), "reason": a.reason,
               "commit": provenance().get("commit"), **now}
        Path(a.baseline).write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"baseline saved: {sum(now['checks'].values())} checks, {len(now['checks'])} ids -> {a.baseline}")
        return 0
    if a.compare:                                           # 기준선과 비교
        bp = Path(a.baseline)
        if not bp.exists():
            print(f"ERROR: no baseline {bp}. Create it with --save --reason ...")
            return 2
        base = json.loads(bp.read_text(encoding="utf-8"))
        problems = compare(now, base)
        res = {"ok": not problems, "problems": problems, "checks": sum(now["checks"].values()),
               "baseline_checks": sum(base["checks"].values()), "baseline_updated": base.get("updated")}
        if a.json:
            print(json.dumps(res, indent=2, ensure_ascii=False))
        else:
            for p in problems:
                print(p)
            print(f"check inventory: {res['checks']} checks now, {res['baseline_checks']} in baseline "
                  f"({base.get('updated')}) -> {'OK' if not problems else 'FAIL'}")
        return 0 if not problems else 1
    if a.json:                                              # 목록 JSON
        print(json.dumps(now, indent=2, ensure_ascii=False))
    else:                                                   # 목록 표
        for cid, n in now["checks"].items():
            print(f"{cid:24s} {n:3d}  {', '.join(now['sites'][cid][:3])}")
        for k, n in now["suppressions"].items():
            print(f"suppress:{k:15s} {n:3d}  {', '.join(now['sites']['suppress:' + k][:3])}")
        print(f"{sum(now['checks'].values())} checks, {len(now['checks'])} ids, {now['files']} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
