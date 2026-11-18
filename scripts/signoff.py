#!/usr/bin/env python3
"""
signoff.py - verif/SIGNOFF.md의 sign-off 기준을 결과 파일로 판정합니다.

  python scripts/signoff.py --level smoke      # push마다 (CI smoke)
  python scripts/signoff.py --level nightly    # 매일 밤 (CI full): seed 5개, 시스템 타이밍
  python scripts/signoff.py --level release    # 출시 판정: nightly + 보드 시험 (사람이 보드를 연결해 돌린 결과)
  python scripts/signoff.py --level smoke --root C:/Users/abc/jenkins/home/workspace/dma-uvm   # 다른 checkout의 out/ 판정

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
    vplan = (root / "verif" / "vplan" / "vplan.md").read_text(encoding="utf-8")  # 검증 계획
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
    unknown_xf = [f"{r['tb']}/{r['test']}" for r in xf if (r["tb"], r["test"]) not in kf]  # known_fail에 없는 XFAIL
    ids = {re.match(r"(BUG-\d+)", why)[1] if re.match(r"(BUG-\d+)", why) else None for why in kf.values()}  # 사유의 버그 ID
    no_doc = sorted(str(i) for i in ids if i is None or not re.search(rf"^## {i}\b", bugs_md, re.M))  # BUGS.md에 없는 ID
    add("S2", "XFAIL = 승인된 known_fail만 (BUGS.md에 ID와 상태 기록)", not unknown_xf and not no_doc,  # 판정
        f"xfail={len(xf)} known_fail={len(kf)} ids={sorted(i for i in ids if i)}" +  # 요약
        (f" unknown={unknown_xf}" if unknown_xf else "") + (f" undocumented={no_doc}" if no_doc else ""),  # 문제
        "verif/sim_cfg.json, verif/BUGS.md")                # 근거 파일

    # S3. 등록된 모든 테스트가 최소 seed 수 이상 실행됨
    reg = {(tb, t) for tb in {r["tb"] for r in runs} for t in cfg["tbs"][tb].get("tests", [])}  # 실행한 TB의 등록 테스트
    cnt = Counter((r["tb"], r["test"]) for r in runs)       # (TB, 테스트) -> 실행 수
    short = sorted(f"{tb}/{t}={cnt[(tb, t)]}" for tb, t in reg if cnt[(tb, t)] < MIN_SEEDS[lv])  # 모자란 테스트
    add("S3", f"등록된 모든 테스트 실행, 테스트당 seed {MIN_SEEDS[lv]}개 이상", bool(reg) and not short,  # 판정
        f"tests={len(reg)} min_seeds={min(cnt[k] for k in reg) if reg else 0}" + (f" short={short[:6]}" if short else ""),  # 요약
        "out/regress/*/summary.json")                       # 근거 파일

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
    all_tests = {t for v in cfg["tbs"].values() for t in v.get("tests", [])}  # 등록된 모든 테스트 이름
    short_name = lambda t: re.sub(r"^(unit|dma)_|_test$", "", t)  # vplan이 쓰는 짧은 이름 (dma_rand_test -> rand)
    top_at = vplan.find("\n## P2")                          # unit 절(P1)과 top 절(P2 이후)의 경계
    part = {"unit": vplan[:top_at], "top": vplan[top_at:]}  # 짧은 이름은 자기 절에서만 찾음 (smoke가 양쪽에 있음)
    top_tests = set(cfg["tbs"].get("top", {}).get("tests", []))  # top 테스트 이름
    unplanned = sorted(t for t in all_tests if t not in vplan  # 전체 이름도
                       and not re.search(rf"(?<![\w-]){re.escape(short_name(t))}(?![\w-])",  # 짧은 이름도
                                         part["top" if t in top_tests else "unit"]))  # 자기 절에 없으면
    open_rows = [ln for ln in vplan.splitlines() if "❌" in ln]  # 실패로 표시된 행
    bad_rows = [ln[:60] for ln in open_rows if not re.search(r"BUG-\d+", ln)]  # 버그 ID가 없는 실패 행
    add("S9", "vplan: 모든 테스트가 계획에 있고, ❌ 행은 버그 ID를 가짐", not unplanned and not bad_rows,  # 판정
        f"tests={len(all_tests)} open_rows={len(open_rows)}" + (f" unplanned={unplanned}" if unplanned else "") +  # 요약
        (f" no_bug_id={bad_rows}" if bad_rows else ""), "verif/vplan/vplan.md")  # 근거 파일

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
