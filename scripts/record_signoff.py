#!/usr/bin/env python3
"""
record_signoff.py - Jenkins 빌드 하나의 결과를 판정해 verif/SIGNOFF.md의 판정 기록 표에 한 줄을 넣습니다.

  python scripts/record_signoff.py --root <Jenkins 작업 폴더> --build "#30" --mode smoke \\
         --result SUCCESS --minutes 10.6 --dry-run      # 넣을 줄만 보여 줌
  python scripts/record_signoff.py ... (--dry-run 없이)  # SIGNOFF.md의 표 맨 위(최신)에 넣음

판정은 이 스크립트가 signoff.py --root <작업 폴더>로 직접 계산합니다(smoke 빌드는 smoke, full 빌드는 nightly 수준).
표의 숫자는 그 작업 폴더의 결과 파일에서 읽습니다: JUnit(테스트 pass/skip/fail), 회귀 요약(runs/fail/xfail),
out/ml/check.json(계획 bin), out/fpga/*/result.json(타이밍, 비트스트림). 같은 빌드 이름이 이미 있으면 넣지 않습니다.
release 판정은 보드 시험 결과가 필요해 이 스크립트로 하지 않습니다.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

from common import ROOT, setup_utf8

setup_utf8()
SIGNOFF = ROOT / "verif" / "SIGNOFF.md"
SECTION = {"smoke": "### Jenkins smoke 추이", "full": "### Jenkins nightly(full) 추이"}


def load(p: Path):
    return json.loads(p.read_text(encoding="utf-8")) if p.exists() else None


def junit_counts(out: Path) -> tuple[int, int, int]:        # (pass, skip, fail)
    t = s = f = 0
    for x in sorted(out.glob("regress/*/junit.xml")):
        r = ET.parse(x).getroot()
        t += int(r.get("tests", 0))
        s += int(r.get("skipped", 0))
        f += int(r.get("failures", 0))
    return t - s - f, s, f


def row(root: Path, a) -> tuple[str, dict]:                 # 표에 넣을 한 줄과 판정 문서
    level = "smoke" if a.mode == "smoke" else "nightly"
    subprocess.run([sys.executable, str(ROOT / "scripts" / "signoff.py"), "--level", level, "--root", str(root)],
                   capture_output=True)
    out = root / "out"
    so = load(out / "signoff" / "signoff.json")
    if not so:
        sys.exit(f"ERROR: signoff.py produced no result under {out}")
    bad = [c["id"] for c in so["criteria"] if c["status"] == "FAIL"]
    verdict = f"**{level} {so['verdict']}**" + (f" (FAIL: {', '.join(bad)})" if bad else "")
    p, s, f = junit_counts(out)
    ooc = load(out / "fpga" / "ooc" / "result.json") or {}
    wns = f"{ooc['wns']:+.3f}ns" if "wns" in ooc else "–"
    sums = [load(x) for x in sorted(out.glob("regress/*/summary.json"))]
    runs = sum(x["runs"] for x in sums if x)
    minutes = f"{a.minutes:g}분" if a.minutes else "–"
    if a.mode == "smoke":
        chk = load(out / "ml" / "check.json")
        how = f"ML 계획 ({runs}회)" if chk else f"계획 없음 ({runs}회)"
        bins = f"{chk['covered']}/{chk['target']}" if chk else "–"
        cells = [a.build, how, a.result, f"{p} / {s} / {f}", wns, bins, verdict, minutes]
    else:
        fail = sum(x["fail"] for x in sums if x)
        xfail = sum(x["xfail"] for x in sums if x)
        cov = next((c["detail"] for c in so["criteria"] if c["id"] == "S4"), "–")
        sysr = load(out / "fpga" / "system" / "result.json") or {}
        tim = f"{sysr['wns']:+.3f}ns / {sysr['whs']:+.3f}ns" if "wns" in sysr else "–"
        arts = sysr.get("artifacts") or {}
        bit = ", ".join(f"`{Path(k).suffix}` {v['bytes']:,}B" for k, v in sorted(arts.items())) or "–"
        cells = [a.build, a.result, f"{runs} / {fail} / {xfail}", f"{p} / {s} / {f}", cov, wns, tim, bit, verdict, minutes]
    return "| " + " | ".join(cells) + " |", so


def insert(md: str, mode: str, line: str, build: str) -> str:  # 표의 맨 위(최신)에 넣음
    i = md.index(SECTION[mode])
    sep = re.compile(r"^\|(?:---\|)+\s*$", re.M).search(md, i)
    if sep is None:
        sys.exit(f"ERROR: no table under '{SECTION[mode]}'")
    nxt = md.find("\n### ", i + 1)
    table = md[sep.end():nxt if nxt > 0 else len(md)]
    if re.search(rf"^\| {re.escape(build)} \|", table, re.M):
        sys.exit(f"ERROR: {build} is already recorded in '{SECTION[mode]}'")
    return md[:sep.end()] + "\n" + line + md[sep.end():]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", required=True, help="Jenkins 작업 폴더 (out/이 있는 checkout)")
    ap.add_argument("--build", required=True, help='표에 쓸 빌드 이름, 예: "#30" 또는 "tb-redesign #4"')
    ap.add_argument("--mode", required=True, choices=["smoke", "full"])
    ap.add_argument("--result", required=True, help="Jenkins 결과 (SUCCESS / UNSTABLE / FAILURE)")
    ap.add_argument("--minutes", type=float, help="빌드 시간 (분)")
    ap.add_argument("--signoff-md", default=str(SIGNOFF), help="기록할 SIGNOFF.md (기본: verif/SIGNOFF.md)")
    ap.add_argument("--dry-run", action="store_true", help="넣을 줄만 출력")
    a = ap.parse_args()
    line, so = row(Path(a.root), a)
    print(f"sign-off {so['level']}: {so['verdict']}")
    print(line)
    if a.dry_run:
        return 0
    p = Path(a.signoff_md)
    p.write_text(insert(p.read_text(encoding="utf-8"), a.mode, line, a.build), encoding="utf-8")
    print(f"recorded in {p}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
