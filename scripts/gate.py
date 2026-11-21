#!/usr/bin/env python3
"""
gate.py - 단계의 완료 기준을 기계로 판정합니다. 에이전트는 "끝났다"를 글로 말하지 않고 이 결과로 말합니다.

  python scripts/gate.py static                 # 빠른 정적 검사만 (시뮬레이션 결과를 보지 않음)
  python scripts/gate.py A                      # A단계 기준: static + 지금 결과로 smoke sign-off
  python scripts/gate.py A --ledger out/loop/<id>/ledger.json   # 판정을 ledger에 덧붙임
  python scripts/gate.py --list                 # 단계와 검사 목록

시뮬레이션은 돌리지 않습니다. 결과가 필요한 검사는 out/에 있는 결과를 판정하고, 결과가 지금 HEAD에서
나온 것인지(출처)도 봅니다. 결과를 새로 만들려면 먼저 regress.py를 돌립니다 (각 검사의 rerun 참고).
결과: out/gate/<stage>.json. 모든 검사가 PASS면 종료 코드 0.
"""
from __future__ import annotations                          # 타입 힌트 지연 평가

import argparse                                             # 명령줄 인자
import json                                                 # 결과 파일
import re                                                   # 판정 줄 찾기
import subprocess                                           # 다른 스크립트 실행
import sys                                                  # 종료 코드, 현재 Python
import time                                                 # 시각
from pathlib import Path                                    # 경로

from common import ROOT, provenance, setup_utf8           # 공통 모듈

setup_utf8()                                                # UTF-8 출력
PY = sys.executable                                         # 지금 Python (CI와 같은 해석기)


def _run(cmd: list[str], timeout: int = 900) -> tuple[int, str]:  # 명령 실행 -> (종료 코드, 출력 끝부분)
    try:
        r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, encoding="utf-8",
                           errors="replace", timeout=timeout)
        out = (r.stdout + r.stderr).strip().splitlines()    # 출력 줄
        return r.returncode, "\n".join(out[-40:])           # 마지막 40줄
    except subprocess.TimeoutExpired:
        return 124, f"timeout after {timeout}s"


def chk_cmd(name: str, cmd: list[str], what: str):          # "이 명령이 0으로 끝나야 함" 검사를 만듦
    def f() -> dict:
        rc, tail = _run(cmd)
        lines = tail.splitlines()
        verdict = [l for l in lines if re.search(r"\b(PASS|FAIL|OK)\b", l) and not l.startswith("|")]  # 판정 줄
        return {"id": name, "what": what, "ok": rc == 0,
                "detail": (verdict or lines or [f"rc={rc}"])[-1],
                "log": tail, "rerun": " ".join(["python"] + [c if c != PY else "python" for c in cmd[1:]])}
    f.__name__ = name
    return f


def chk_results_fresh() -> dict:                            # 회귀 결과가 지금 HEAD에서 나왔는지
    head = provenance()                                     # 지금 checkout
    bad, seen = [], []                                      # 문제, 본 요약
    for name in ("unit", "top"):
        sj = ROOT / "out" / "regress" / name / "summary.json"
        if not sj.exists():
            bad.append(f"no out/regress/{name}/summary.json")
            continue
        s = json.loads(sj.read_text(encoding="utf-8"))
        p = s.get("provenance") or {}
        seen.append(name)
        if p.get("commit") != head["commit"]:
            bad.append(f"{name}: results from {str(p.get('commit'))[:8]}, HEAD is {str(head['commit'])[:8]}")
        if p.get("hw_hash") != head["hw_hash"]:
            bad.append(f"{name}: HW/ hash {p.get('hw_hash')} != checkout {head['hw_hash']}")
    note = " (checkout has uncommitted changes; results reflect the files at run time)" if head["dirty"] else ""
    return {"id": "results_fresh", "what": "회귀 결과가 지금 HEAD와 HW/에서 나옴", "ok": not bad,
            "detail": ("; ".join(bad) or f"{', '.join(seen)} from {str(head['commit'])[:8]}") + note,
            "rerun": "python scripts/regress.py --suite unit --name unit --plan verif/regress_plan.json && "
                     "python scripts/regress.py --suite top --name top --plan verif/regress_plan.json"}


def chk_agent_trials() -> dict:                             # C단계: 에이전트 시험을 실제로 돌린 기록
    """out/loop/stageC/ledger.json에 두 시험의 기록이 있어야 함 (orchestrator가 실제 결과로 남김).
    trial_weakened: 일부러 검사를 낮춘 diff를 hook이 잡고(hook_caught) tb-reviewer가 "수정 요청"
    trial_e2e: planner -> builder(worktree) -> tb-reviewer 승인 -> 작업 폴더의 gate static PASS"""
    lp = ROOT / "out" / "loop" / "stageC" / "ledger.json"
    ent = json.loads(lp.read_text(encoding="utf-8"))["entries"] if lp.exists() else []
    last = {e.get("kind"): e for e in ent}                  # 종류마다 마지막 기록
    w, e2e = (last.get("trial_weakened") or {}).get("data", {}), (last.get("trial_e2e") or {}).get("data", {})
    bad = []
    if not (w.get("hook_caught") is True and w.get("reviewer_verdict") == "수정 요청"):
        bad.append(f"trial_weakened not passed ({w or 'no record'})")
    if not (e2e.get("reviewer_verdict") == "승인" and e2e.get("gate_static") == "PASS" and e2e.get("worktree")):
        bad.append(f"trial_e2e not passed ({e2e or 'no record'})")
    return {"id": "agent_trials", "what": "에이전트 시험 기록 (검사 약화 잡기, 끝까지 돌린 작업)", "ok": not bad,
            "detail": "; ".join(bad) or "trial_weakened caught, trial_e2e approved and gate static PASS",
            "rerun": "verify-stage로 시험 작업을 돌리고 ledger_append(loop_id=stageC)로 기록"}


def chk_same_results(before: str, after: str):              # 두 회귀의 판정이 (tb, test, seed)마다 같은지
    """코드 내용이 바뀌지 않아야 하는 작업(폴더 이동) 뒤에 씀. 실행 목록도 같아야 함 (빠진 실행 없음)."""
    def f() -> dict:
        def load(n):
            p = ROOT / "out" / "regress" / n / "summary.json"
            return {(r["tb"], r["test"], r["seed"]): r["verdict"]
                    for r in json.loads(p.read_text(encoding="utf-8"))["results"]} if p.exists() else None
        a, b = load(before), load(after)
        if a is None or b is None:
            ok, detail = False, f"missing out/regress/{before if a is None else after}/summary.json"
        else:
            diff = [f"{k[0]}/{k[1]}/{k[2]}: {a[k]} -> {b[k]}" for k in sorted(set(a) & set(b)) if a[k] != b[k]]
            only = sorted(set(a) ^ set(b))
            ok = not diff and not only and bool(a)
            detail = (f"{len(a)} runs, all verdicts equal" if ok else
                      "; ".join(diff[:5] + [f"runs only in one: {len(only)}"] if only else diff[:5]))
        return {"id": f"same_{before}_{after}", "what": f"{before}와 {after}의 판정이 같음", "ok": ok,
                "detail": detail, "rerun": f"python scripts/regress.py --suite all --seeds 1 --first-seed <seed> --name {after}"}
    f.__name__ = f"chk_same_{before}_{after}"
    return f


STAGE2_TESTS = ("dma_reset_test", "dma_irq_ready_test", "dma_busy_reg_write_test", "dma_start_busy_test",
                "dma_auto_restart_test", "dma_reset_mid_job_test", "dma_size_128mib_test",
                "dma_aw_wait_after_job_test", "dma_slow_b_test")          # TB 2단계에서 만든 top 테스트


def hypothesis_problems(plan: dict, cfg: dict) -> list[str]:
    """가설이 모두 판정됐고 근거 테스트와 BUG가 맞게 이어졌는지. confirmed: kind=bug면 test가 그 BUG의 known_fail에,
    kind=note면 어느 known_fail에도 없음(PASS 테스트). refuted: test가 known_fail에 없음."""
    bugs = {b["id"]: b for b in plan.get("bugs", [])}
    all_kf = {t for b in bugs.values() for t in b.get("known_fail", [])}
    probs = []
    for h in plan.get("hypotheses", []):
        hid, st, test = h["id"], h.get("status"), h.get("test") or ""
        tb, _, name = test.partition("/")
        if st not in ("confirmed", "refuted"):
            probs.append(f"{hid}: status {st} (confirmed 또는 refuted여야 함)")
        if not test or name not in cfg.get("tbs", {}).get(tb, {}).get("tests", []):
            probs.append(f"{hid}: test '{test}' is not registered in sim_cfg.json")
        if st == "confirmed":
            b = bugs.get(h.get("bug"))
            if b is None:
                probs.append(f"{hid}: confirmed but bug '{h.get('bug')}' is not in plan.toml bugs")
            elif b.get("kind") == "bug" and test not in b.get("known_fail", []):
                probs.append(f"{hid}: {test} is not in {b['id']} known_fail")
            elif b.get("kind") == "note" and test in all_kf:
                probs.append(f"{hid}: note {b['id']} but {test} is a known_fail")
        if st == "refuted" and test in all_kf:
            probs.append(f"{hid}: refuted but {test} is a known_fail")
    return probs


def xfail_problems(results: list[dict], root: Path) -> list[str]:
    """XFAIL이 TB 한계가 아니라 기대한 이유로 났는지: 로그에 PRED_UNSUPPORTED, SCENARIO_MISS, UVM_FATAL이 없고
    이유에 timeout, 종료 코드, 시뮬레이터 Error/Fatal 줄이 없어야 함."""
    probs = []
    for r in results:
        if r.get("verdict") != "XFAIL":
            continue
        tag = f"{r['tb']}/{r['test']}/{r['seed']}"
        bad = [x for x in r.get("reasons", []) if re.search(r"timeout|exit|simulator|NO_RESULT", x, re.I)]
        if bad:
            probs.append(f"{tag}: reasons {bad}")
        log = root / r.get("run_dir", "") / "run.log"
        if not log.exists():
            probs.append(f"{tag}: no run.log")
            continue
        txt = log.read_text(encoding="utf-8", errors="replace")
        hits = [k for k, pat in (("PRED_UNSUPPORTED", r"\[PRED_UNSUPPORTED\]"), ("SCENARIO_MISS", r"\[SCENARIO_MISS\]"),
                                 ("UVM_FATAL", r"^UVM_FATAL (?!:)")) if re.search(pat, txt, re.M)]
        if hits:
            probs.append(f"{tag}: log has {', '.join(hits)}")
    return probs


def chk_hypotheses_closed() -> dict:                         # 2단계: 가설이 모두 판정되고 BUG/NOTE와 테스트가 이어짐
    import tomllib
    plan = tomllib.loads((ROOT / "verif" / "plan.toml").read_text(encoding="utf-8"))
    cfg = json.loads((ROOT / "verif" / "sim_cfg.json").read_text(encoding="utf-8"))
    probs = hypothesis_problems(plan, cfg)
    return {"id": "hypotheses_closed", "what": "가설이 모두 confirmed/refuted, 테스트 등록, BUG known_fail 또는 NOTE와 연결",
            "ok": not probs, "detail": "; ".join(probs[:6]) or f"{len(plan.get('hypotheses', []))} hypotheses closed",
            "rerun": "confirm-hypothesis로 판정 → file-rtl-bug로 등록 → python scripts/plan_check.py --write"}


def _top_results() -> list[dict]:
    p = ROOT / "out" / "regress" / "top" / "summary.json"
    return json.loads(p.read_text(encoding="utf-8"))["results"] if p.exists() else []


def chk_stage2_seeds() -> dict:                              # 2단계 새 테스트가 회귀에서 seed 3개 이상
    res = _top_results()
    cnt = {t: sum(1 for r in res if r["tb"] == "top" and r["test"] == t) for t in STAGE2_TESTS}
    short = [f"{t}={n}" for t, n in cnt.items() if n < 3]
    return {"id": "stage2_seeds", "what": "2단계 새 top 테스트 9개가 각각 seed 3개 이상", "ok": bool(res) and not short,
            "detail": ("no out/regress/top/summary.json" if not res else "; ".join(short) or "all >= 3 seeds"),
            "rerun": "python scripts/regress.py --suite top --name top --plan verif/regress_plan.json --seeds 3"}


def chk_xfail_clean() -> dict:                               # XFAIL이 TB 한계가 아니라 기대한 이유로 남
    res = _top_results()
    probs = xfail_problems(res, ROOT)
    n = sum(1 for r in res if r.get("verdict") == "XFAIL")
    return {"id": "xfail_clean", "what": "XFAIL 로그에 PRED_UNSUPPORTED/SCENARIO_MISS/UVM_FATAL/timeout 없음",
            "ok": bool(res) and not probs, "detail": "; ".join(probs[:5]) or f"{n} XFAIL runs clean",
            "rerun": "python scripts/regress.py --suite top --name top --plan verif/regress_plan.json --seeds 3"}


STATIC = [                                                  # 시뮬레이션 없이 도는 검사 (Jenkins Lint 단계와 같음)
    chk_cmd("hook_tests", [PY, ".claude/hooks/test_hooks.py"], "hook 회귀 테스트 (실행 전, 실행 후, git hook)"),
    chk_cmd("script_tests", [PY, "-m", "unittest", "discover", "-s", "scripts/tests", "-t", "scripts"],
            "scripts/ 단위 테스트 (판정, 파서, sign-off 규칙)"),
    chk_cmd("check_inventory", [PY, "scripts/check_inventory.py", "--compare"], "검사가 기준선보다 줄지 않음 (규칙 5)"),
    chk_cmd("plan_check", [PY, "scripts/plan_check.py"], "plan.toml <-> sim_cfg/검사/커버리지/BUGS.md, vplan.md 최신"),
    chk_cmd("check_docs", [PY, "scripts/check_docs.py"], "문서의 경로, 클래스 이름, 생성 구간이 최신"),
    chk_cmd("check_agents", [PY, "scripts/check_agents.py"], "에이전트와 스킬 정의 (도구 이름, 쓰기 권한, 박힌 경로, 없는 이름)"),
]
STAGES = {                                                  # 단계 -> 검사 목록
    "static": STATIC,
    "A": STATIC + [
        chk_results_fresh,
        chk_cmd("signoff_smoke", [PY, "scripts/signoff.py", "--level", "smoke"], "smoke sign-off (S1~S6, S9~S11)"),
    ],
    "B": STATIC + [                                         # MCP: 모든 도구, worktree 동시 빌드와 잠금, 작업 재시작/취소, 신호 추적
        chk_cmd("mcp_selftest_full", [str(ROOT / "mcp" / ".venv" / "Scripts" / "python.exe"),
                                      "mcp/vivado_mcp/selftest.py", "--full"],
                "vivado MCP 자체 시험 (--full)"),
    ],
    "C": STATIC + [chk_agent_trials],                       # 에이전트와 스킬: 정의 검사(check_agents) + 시험 기록
    "0-1": STATIC + [                                       # TB 폴더 이동: 코드가 그대로이므로 같은 seed의 판정이 이동 전과 같아야 함
        chk_same_results("pre01_s1", "post01_s1"),
        chk_same_results("pre01_s7", "post01_s7"),
    ],
    "1": STATIC + [chk_cmd(f"lint_{tb}", [PY, "scripts/sim.py", "lint", "--tb", tb], f"{tb} TB 컴파일")  # TB 1단계: 구조 재편
                   for tb in ("rtl", "ref_adder_fixed", "xsim_msgs", "fifo", "skid", "adder", "top")] + [
        chk_results_fresh,
        chk_cmd("signoff_smoke", [PY, "scripts/signoff.py", "--level", "smoke"],
                "smoke sign-off: 회귀 fail 0(checker self-test 포함), XFAIL은 known_fail만, 커버리지 100%, 계획 bin 전부, 출처, RTL 해시"),
    ],
    "2": STATIC + [chk_cmd(f"lint_{tb}", [PY, "scripts/sim.py", "lint", "--tb", tb], f"{tb} TB 컴파일")  # TB 2단계: 새 시나리오와 가설
                   for tb in ("rtl", "ref_adder_fixed", "xsim_msgs", "fifo", "skid", "adder", "top")] + [
        chk_results_fresh,
        chk_cmd("signoff_smoke", [PY, "scripts/signoff.py", "--level", "smoke"],
                "smoke sign-off: 회귀 fail 0, XFAIL은 known_fail만, 커버리지 100%, 계획 bin 전부, 출처, RTL 해시"),
        chk_hypotheses_closed,
        chk_stage2_seeds,
        chk_xfail_clean,
    ],
    "0-2": STATIC + [                                       # TB 이름 바꾸기: 랜덤 값이 달라질 수 있어 판정 비교 대신 smoke sign-off 전체
        chk_results_fresh,
        chk_cmd("signoff_smoke", [PY, "scripts/signoff.py", "--level", "smoke"],
                "smoke sign-off: 회귀 fail 0, XFAIL은 known_fail만, 커버리지 100%, 계획 bin 전부, 출처, RTL 해시"),
    ],
}


def main() -> int:                                          # 진입점
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("stage", nargs="?", help="단계 이름 (" + ", ".join(STAGES) + ")")
    ap.add_argument("--list", action="store_true", help="단계와 검사 목록")
    ap.add_argument("--ledger", help="판정을 덧붙일 ledger.json (예: out/loop/<id>/ledger.json)")
    a = ap.parse_args()
    if a.list or not a.stage:
        for st, checks in STAGES.items():
            print(f"{st}: " + ", ".join(c.__name__.removeprefix("chk_") for c in checks))
        return 0
    if a.stage not in STAGES:
        ap.error(f"unknown stage {a.stage}")
    t0 = time.time()
    res = [c() for c in STAGES[a.stage]]                    # 검사 실행
    ok = all(r["ok"] for r in res)
    doc = {"stage": a.stage, "verdict": "PASS" if ok else "FAIL", "time": time.strftime("%Y-%m-%d %H:%M:%S"),
           "elapsed_s": round(time.time() - t0, 1), "provenance": provenance(),
           "checks": [{k: v for k, v in r.items() if k != "log"} for r in res]}
    od = ROOT / "out" / "gate"
    od.mkdir(parents=True, exist_ok=True)
    (od / f"{a.stage}.json").write_text(json.dumps(doc, indent=2, ensure_ascii=False), encoding="utf-8")
    if a.ledger:                                            # ledger에 덧붙임 (다른 세션이 이어 갈 수 있게)
        lp = Path(a.ledger)
        lp.parent.mkdir(parents=True, exist_ok=True)
        led = json.loads(lp.read_text(encoding="utf-8")) if lp.exists() else {"entries": []}
        led["entries"].append({"kind": "gate", **doc})
        lp.write_text(json.dumps(led, indent=2, ensure_ascii=False), encoding="utf-8")
    for r in res:
        print(f"[{'PASS' if r['ok'] else 'FAIL'}] {r['id']:16s} {r['detail'][:150]}")
        if not r["ok"]:
            if r.get("log"):
                print("      " + r["log"].replace("\n", "\n      ")[:1500])
            print(f"      rerun: {r['rerun']}")
    print(f"gate {a.stage}: {doc['verdict']} ({doc['elapsed_s']}s) -> out/gate/{a.stage}.json")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
