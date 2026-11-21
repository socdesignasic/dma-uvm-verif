#!/usr/bin/env python3
"""
signoff.py - verif/SIGNOFF.md의 sign-off 기준을 결과 파일로 판정합니다.

  python scripts/signoff.py --level smoke      # push마다 (CI smoke)
  python scripts/signoff.py --level nightly    # 매일 밤 (CI full): seed 5개, 시스템 타이밍
  python scripts/signoff.py --level release    # 출시 판정: nightly + 보드 시험 (사람이 보드를 연결해 돌린 결과)
  python scripts/signoff.py --level smoke --root <JENKINS_HOME>/workspace/dma-uvm   # 다른 checkout의 out/ 판정

기준마다 PASS / FAIL / N/A(이 수준에서는 보지 않음)를 내고, 모두 PASS면 종료 코드 0.
결과: out/signoff/signoff.json, out/signoff/signoff.md
"""
from __future__ import annotations                          # 타입 힌트를 문자열로 지연 평가

import argparse                                             # 명령줄 인자
import json                                                 # 결과 파일 읽기/쓰기
import re                                                   # 보고서 파싱
import sys                                                  # 종료 코드, 출력 인코딩
import time                                                 # 시각
from collections import Counter                             # seed 수 세기
from pathlib import Path                                    # 경로 처리

from common import hw_hash                                  # HW/ 내용 해시 (scripts/common.py)
from plan_check import check as plan_check                  # plan.toml <-> 코드 검사
from plan_check import load as load_plan                    # plan.toml 읽기

for _s in (sys.stdout, sys.stderr):                         # 표준 출력과 오류 출력마다
    _s.reconfigure(encoding="utf-8", errors="replace")      # UTF-8로 (Windows 코드페이지 949 대비)

LEVELS = ["smoke", "nightly", "release"]                    # 판정 수준 (뒤로 갈수록 엄격)
MIN_SEEDS = {"smoke": 1, "nightly": 5, "release": 5}        # 테스트마다 최소 seed 수


def load(p: Path):                                          # JSON 파일 읽기 (없으면 None)
    return json.loads(p.read_text(encoding="utf-8")) if p.exists() else None  # 있으면 파싱


def latest(d: Path, name: str = "result.json"):             # 시각 이름 하위 디렉터리 중 가장 최근 결과
    runs = sorted(d.glob(f"*/{name}")) if d.exists() else []  # out/board/<시각>/result.json 목록
    return (runs[-1], load(runs[-1])) if runs else (None, None)  # 이름순 = 시각순


def main() -> int:                                          # 진입점
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)  # 인자 파서
    ap.add_argument("--level", choices=LEVELS, default="smoke")  # 판정 수준
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent), help="out/이 있는 checkout")  # 판정할 checkout
    ap.add_argument("--regress", nargs="+", default=["unit", "top"], help="out/regress/ 아래 회귀 이름")  # 회귀 결과
    a = ap.parse_args()                                     # 인자 파싱
    root, lv = Path(a.root), a.level                        # 루트, 수준
    out = root / "out"                                      # 결과 디렉터리
    at_least = lambda level: LEVELS.index(lv) >= LEVELS.index(level)  # 이 수준 이상에서만 보는 기준인지
    cfg = load(root / "verif" / "sim_cfg.json")             # TB와 테스트 목록, known_fail
    bugs_md = (root / "verif" / "BUGS.md").read_text(encoding="utf-8")  # 버그 문서
    pc = plan_check(root)                                   # 검증 계획 검사 (S2, S9)
    plan = load_plan(root)                                  # plan.toml (승인된 RTL 해시)
    res = []                                                # 기준별 결과

    def add(cid: str, title: str, ok, detail: str, evidence: str = ""):  # 결과 한 줄 추가
        st = "N/A" if ok is None else ("PASS" if ok else "FAIL")  # None은 이 수준에서 안 봄
        res.append({"id": cid, "title": title, "status": st, "detail": detail, "evidence": evidence})  # 저장

    # S1. 회귀: 빌드 실패 0, 기대와 다른 실행 0 (FAIL, XPASS, NO_RESULT 모두 포함)
    sums = {n: load(out / "regress" / n / "summary.json") for n in a.regress}  # 회귀 요약
    missing = [n for n, s in sums.items() if s is None]     # 없는 회귀
    runs = [r for s in sums.values() if s for r in s["results"]]  # 모든 실행 결과
    bad = [r for r in runs if not r["ok"]]                  # 기대와 다른 실행
    bfail = [t for s in sums.values() if s for t in s.get("build_fail", [])]  # 빌드 실패 TB
    add("S1", "회귀 fail 0 (XPASS, NO_RESULT 포함), 빌드 실패 0", not missing and not bad and not bfail,  # 판정
        f"runs={len(runs)} fail={len(bad)} build_fail={len(bfail)}" + (f" missing={missing}" if missing else "") +  # 요약
        "".join(f"; {r['tb']}/{r['test']} seed={r['seed']} {r['verdict']}" for r in bad[:5]),  # 실패 몇 개
        ", ".join(f"out/regress/{n}/summary.json" for n in a.regress))  # 근거 파일

    # S2. 예상된 실패(XFAIL)는 모두 known_fail에 있고, 그 known_fail은 BUGS.md에 같은 ID로 기록돼 있음
    kf = {(tb, t): why for tb, v in cfg["tbs"].items() for t, why in (v.get("known_fail") or {}).items()}  # (TB, 테스트) -> 사유
    xf = [r for r in runs if r["verdict"] == "XFAIL"]       # 예상된 실패
    unknown_xf = [f"{r['tb']}/{r['test']}" for r in xf if (r["tb"], r["test"]) not in kf]  # 승인되지 않은 XFAIL
    kf_probs = [p for p in pc["problems"] if p.startswith("KNOWN_FAIL")]  # known_fail <-> plan.toml bugs <-> BUGS.md
    add("S2", "XFAIL = 승인된 known_fail만 (plan.toml bugs, BUGS.md와 일치)", not unknown_xf and not kf_probs,
        f"xfail={len(xf)} known_fail={len(kf)}" + (f" unknown={unknown_xf}" if unknown_xf else "") +
        "".join(f"; {p}" for p in kf_probs[:4]),
        "verif/sim_cfg.json, verif/plan.toml, verif/BUGS.md (plan_check.py)")

    # S3. 등록된 모든 테스트가 최소 seed 수 이상 실행됨
    expect_tbs = {tb for tb, v in cfg["tbs"].items() if v.get("tests")}  # 회귀에 나와야 하는 TB (테스트가 등록된 모든 TB)
    seen_tbs = {r["tb"] for r in runs}                      # 회귀에 실제로 나온 TB
    missing_tbs = sorted(expect_tbs - seen_tbs - set(bfail))  # 통째로 빠진 TB (빌드 실패는 S1에서 봄)
    reg = {(tb, t) for tb in expect_tbs for t in cfg["tbs"][tb].get("tests", [])}  # 등록된 모든 (TB, 테스트)
    cnt = Counter((r["tb"], r["test"]) for r in runs)       # (TB, 테스트) -> 실행 수
    short = sorted(f"{tb}/{t}={cnt[(tb, t)]}" for tb, t in reg if tb in seen_tbs and cnt[(tb, t)] < MIN_SEEDS[lv])  # seed가 모자란 테스트
    add("S3", f"등록된 모든 TB와 테스트 실행, 테스트당 seed {MIN_SEEDS[lv]}개 이상", bool(reg) and not short and not missing_tbs,
        f"tbs={len(seen_tbs)}/{len(expect_tbs)} tests={len(reg)} min_seeds={min(cnt[k] for k in reg) if reg else 0}" +
        (f" missing_tbs={missing_tbs}" if missing_tbs else "") + (f" short={short[:6]}" if short else ""),
        "out/regress/*/summary.json")

    # S4. 기능 커버리지 100% (회귀에 나온 TB마다, xcrg 병합 보고서)
    scores, nocov = {}, []                                  # TB -> 점수, 보고서 없는 TB
    for tb in sorted({r["tb"] for r in runs}):              # 회귀에 나온 TB마다
        rep = out / tb / "cov" / "func" / "xcrg_func_cov_report.txt"  # 기능 커버리지 보고서
        m = re.search(r"Coverage Score\s*:,\s*([\d.]+)", rep.read_text(encoding="utf-8", errors="replace")) if rep.exists() else None  # 점수
        if m:                                               # 점수가 있으면
            scores[tb] = float(m[1])                        # 기록
        else:                                               # 없으면
            nocov.append(tb)                                # 보고서 없음
    add("S4", "기능 커버리지 100% (모든 TB)", bool(scores) and not nocov and all(v >= 100 for v in scores.values()),  # 판정
        " ".join(f"{tb}={v:g}" for tb, v in scores.items()) + (f" no_report={nocov}" if nocov else ""),  # TB별 점수
        "out/<tb>/cov/func/xcrg_func_cov_report.txt (sim.py cov-report)")  # 근거 파일

    # S5. (smoke) ML 회귀 계획의 목표 bin을 모두 채움
    chk = load(out / "ml" / "check.json")                   # ml_regress.py check 결과
    add("S5", "smoke: 회귀 계획의 목표 bin 전부 (ml_regress.py check)",  # 판정 (smoke에서만, 결과가 있을 때)
        (chk is not None and chk["ok"]) if lv == "smoke" and chk is not None else None,
        f"{chk['covered']}/{chk['target']} bins, {chk.get('runs')}/{chk.get('runs_total', chk.get('runs'))} runs read" if chk else "계획 없이 돈 회귀 (check.json 없음)",  # 요약
        "out/ml/check.json")                                # 근거 파일

    # S6. DMA 단독(OOC) 100MHz 타이밍: WNS, WHS >= 0
    ooc = load(out / "fpga" / "ooc" / "result.json")        # OOC 결과
    add("S6", "FPGA OOC 타이밍 WNS ≥ 0, WHS ≥ 0 (100MHz)", ooc is not None and ooc["wns"] >= 0 and ooc["whs"] >= 0,  # 판정
        f"WNS={ooc['wns']} WHS={ooc['whs']} part={ooc.get('part')} git={ooc.get('git')}" if ooc else "결과 없음 (fpga.py ooc)",  # 요약
        "out/fpga/ooc/result.json")                         # 근거 파일

    # S7. (nightly 이상) 시스템 빌드(PS + DMA) 타이밍과 비트스트림
    sysr = load(out / "fpga" / "system" / "result.json")    # 시스템 빌드 결과
    sys_ok = sysr is not None and sysr.get("wns", -1) >= 0 and sysr.get("whs", -1) >= 0  # 타이밍 충족
    add("S7", "시스템 빌드 WNS ≥ 0, WHS ≥ 0, 비트스트림 생성", sys_ok if at_least("nightly") else None,  # 판정
        f"WNS={sysr.get('wns')} WHS={sysr.get('whs')} git={sysr.get('git')}" if sysr else "결과 없음 (fpga.py system)",  # 요약
        "out/fpga/system/result.json")                      # 근거 파일

    # S8. (release) 실보드 시험: JTAG와 ARM C 모두 최근 결과 PASS
    bj_p, bj = latest(out / "board")                        # JTAG 보드 시험 최근 결과
    bc_p, bc = latest(out / "board_c")                      # C 보드 시험 최근 결과
    j_ok = bool(bj) and all(r.get("verdict") == "PASS" for r in bj["results"])  # JTAG 모두 PASS
    c_ok = bool(bc) and bc.get("verdict") == "PASS" and bc.get("uart_agrees_with_mailbox") is not False  # C PASS, UART 일치
    add("S8", "실보드 시험 PASS (JTAG board.py, ARM C board_c.py)", (j_ok and c_ok) if at_least("release") else None,  # 판정
        (f"jtag={'PASS' if j_ok else 'FAIL'} ({bj_p.parent.name})" if bj else "jtag=없음") + ", " +  # JTAG
        (f"c={'PASS' if c_ok else 'FAIL'} ({bc_p.parent.name})" if bc else "c=없음"),  # C
        "out/board/<시각>/result.json, out/board_c/<시각>/result.json")  # 근거 파일

    # S9. 검증 계획: 등록된 모든 테스트가 vplan.md에 있고, 실패(❌) 행은 버그 ID를 가짐
    plan_probs = [p for p in pc["problems"] if not p.startswith("KNOWN_FAIL")]  # 계획 자체의 문제 (known_fail은 S2)
    add("S9", "검증 계획: 모든 테스트가 기능에 있고, blocked 기능은 버그/가설을 가리키며, vplan.md가 최신",
        not plan_probs,
        f"features={pc.get('features')} tests={pc.get('tests_planned')}/{pc.get('tests_registered')}" +
        "".join(f"; {p}" for p in plan_probs[:4]),
        "verif/plan.toml, verif/vplan/vplan.md (plan_check.py)")

    # S10: 근거 파일의 출처가 하나의 커밋이고, FPGA와 보드 결과가 그 RTL을 썼는지
    approved = (plan.get("rtl") or {}).get("approved_hw_hash")  # 승인된 HW/ 해시
    prov = []                                               # (근거 이름, 커밋, 수정 여부, HW 해시)
    for n, s in sums.items():                               # 회귀 요약마다
        if s:
            p_ = s.get("provenance") or {}
            prov.append((f"regress/{n}", p_.get("commit"), p_.get("dirty"), p_.get("hw_hash")))
            for c in s.get("commits", []):                  # 실행마다 쓴 커밋
                if c != p_.get("commit"):
                    prov.append((f"regress/{n} run", None if c == "None" else c, None, None))
    for name, r in (("fpga/ooc", ooc), ("fpga/system", sysr if at_least("nightly") else None)):
        if r:
            p_ = r.get("provenance") or {}
            prov.append((name, p_.get("commit"), p_.get("dirty"), p_.get("hw_hash")))
    commits = {c for _, c, _, _ in prov}                    # 쓰인 커밋
    no_prov = sorted(n for n, c, _, _ in prov if not c)     # 출처가 없는 근거 (예전 스크립트로 만든 결과)
    dirty = sorted(n for n, _, d, _ in prov if d)           # 수정된 checkout에서 만든 근거
    board_bad = []                                          # 보드 결과가 승인된 RTL의 비트스트림이 아님
    if at_least("release"):
        xsas = {}                                           # XSA sha256 -> 그 시스템 빌드의 HW 해시
        for d in sorted((out / "fpga").glob("system*/result.json")):
            r = load(d) or {}
            for k, v in (r.get("artifacts") or {}).items():
                if k.endswith(".xsa"):
                    xsas[v.get("sha256")] = (r.get("provenance") or {}).get("hw_hash")
        for name, b in (("board", bj), ("board_c", bc)):
            if b and xsas.get(b.get("xsa_sha256")) != approved:
                board_bad.append(f"{name}: xsa {str(b.get('xsa_sha256'))[:12]} not from an approved-RTL system build")
    ok10 = bool(prov) and len(commits) == 1 and not no_prov and not board_bad and not (dirty and at_least("release"))
    add("S10", "근거 파일이 모두 같은 커밋에서 나옴 (release는 수정 없는 checkout, 보드는 승인된 RTL의 XSA)", ok10,
        f"commits={sorted(str(c)[:8] for c in commits)}" + (f" no_provenance={no_prov}" if no_prov else "") +
        (f" dirty={dirty}" if dirty else "") + "".join(f"; {x}" for x in board_bad),
        "summary.json provenance, out/fpga/*/result.json, out/board*/<시각>/result.json")

    # S11: RTL이 사람이 승인한 그대로인지
    now_hw = hw_hash(root)                                  # 지금 checkout의 HW/ 해시
    ev_hw = {h for _, _, _, h in prov if h}                 # 근거 파일들이 본 HW/ 해시
    add("S11", "HW/ 내용 해시 = plan.toml의 승인된 값 (checkout과 모든 근거)",
        bool(approved) and now_hw == approved and ev_hw <= {approved},
        f"approved={approved} checkout={now_hw} evidence={sorted(ev_hw)}",
        "verif/plan.toml [rtl], scripts/common.py hw_hash")

    # 판정과 열린 버그(waiver) 목록
    judged = [r for r in res if r["status"] != "N/A"]       # 이 수준에서 본 기준
    ok = all(r["status"] == "PASS" for r in judged)         # 모두 PASS인지
    waivers = [{"id": m[1], "title": m[2].strip(),          # BUGS.md의 버그와 상태
                "status": (re.search(r"\*\*상태:\*\*\s*(.+)", m[3]) or [None, "?"])[1].strip()}
               for m in re.finditer(r"^## (BUG-\d+):(.*)\n((?:(?!^## ).*\n?)*)", bugs_md, re.M)]  # 버그 섹션마다
    doc = {"level": lv, "verdict": "PASS" if ok else "FAIL", "time": time.strftime("%Y-%m-%d %H:%M:%S"),  # 요약
           "root": str(root), "criteria": res, "waivers": waivers}  # 기준별 결과, 열린 버그
    od = out / "signoff"                                    # 결과 디렉터리
    od.mkdir(parents=True, exist_ok=True)                   # 생성
    (od / "signoff.json").write_text(json.dumps(doc, indent=2, ensure_ascii=False), encoding="utf-8")  # JSON 저장
    md = [f"# Sign-off ({lv}): {doc['verdict']}", "", f"{doc['time']} · `{root}`", "",  # Markdown 보고서
          "| ID | 기준 | 판정 | 내용 |", "|---|---|---|---|"]  # 표 머리
    md += [f"| {r['id']} | {r['title']} | {r['status']} | {r['detail']} |" for r in res]  # 기준마다 한 줄
    md += ["", "열린 버그 (known_fail로 승인된 waiver):", ""] + [f"- {w['id']}:{w['title']} ({w['status']})" for w in waivers]  # waiver
    (od / "signoff.md").write_text("\n".join(md) + "\n", encoding="utf-8")  # 저장
    print("\n".join(md))                                    # 화면 출력
    return 0 if ok else 1                                   # 모두 PASS면 0


if __name__ == "__main__":                                  # 스크립트로 실행될 때만
    sys.exit(main())                                        # main의 반환값을 종료 코드로
