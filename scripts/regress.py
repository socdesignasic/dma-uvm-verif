#!/usr/bin/env python3
"""
regress.py - 선택한 TB에 등록된 모든 테스트를 seed N개로 병렬 실행합니다.

  python scripts/regress.py --suite unit --seeds 3
  python scripts/regress.py --suite all  --seeds 2 --jobs 6
  python scripts/regress.py --tb top --tests dma_smoke_test dma_irq_test
  python scripts/regress.py --plan verif/regress_plan.json               # ml_regress.py가 만든 계획 (테스트마다 seed 수)
  python scripts/regress.py --suite unit --plan verif/regress_plan.json  # unit TB만 계획대로

TB마다 한 번씩 (차례로) 빌드한 뒤, (tb, test, seed) 작업을 스레드 풀에서 실행합니다.
실행마다 `sim.py run --no-build --isolate`를 부르므로 단일 실행과 같은 코드 경로를 타고,
다만 snapshot의 개인 사본에서 돕니다.
테스트마다 첫 seed는 --first-seed(재현 가능)이고, 나머지는 랜덤입니다.
out/regress/<name>/summary.json과 junit.xml을 씁니다.
모든 실행이 기대와 맞을 때만 종료 코드 0 (PASS, 또는 알려진 버그는 XFAIL).
"""
from __future__ import annotations                          # 타입 힌트를 문자열로 지연 평가

import argparse                                             # 명령줄 인자 파싱
import json                                                 # sim_cfg.json, result.json, summary.json 처리
import os                                                   # CPU 개수 확인
import random                                               # 랜덤 seed 생성
import subprocess                                           # sim.py 실행
import sys                                                  # 종료 코드, 현재 Python 경로
import time                                                 # 걸린 시간 측정
from concurrent.futures import ThreadPoolExecutor, as_completed  # 병렬 실행용 스레드 풀
from pathlib import Path                                    # 경로 처리
from xml.sax.saxutils import escape                         # JUnit XML 특수문자 이스케이프

# 한글 출력이 Jenkins/MCP(UTF-8로 읽음)에서 깨지지 않도록 출력 인코딩을 UTF-8로 고정
for _s in (sys.stdout, sys.stderr):                         # 표준 출력과 표준 오류 각각
    if hasattr(_s, "reconfigure"):                          # reconfigure를 지원하면
        _s.reconfigure(encoding="utf-8", errors="replace")  # UTF-8로 바꾸고, 못 바꾸는 문자는 ?로

ROOT = Path(__file__).resolve().parent.parent               # 저장소 루트
SIM = [sys.executable, str(ROOT / "scripts" / "sim.py")]    # sim.py를 지금 Python으로 실행하는 명령 앞부분
CFG = json.loads((ROOT / "verif" / "sim_cfg.json").read_text(encoding="utf-8"))  # 테스트벤치 설정 읽기
UNIT = [k for k, v in CFG["tbs"].items() if v.get("tests") and k != "top"]  # 테스트가 등록된 TB 중 top이 아닌 것 = unit suite
SUITES = {"unit": UNIT, "top": ["top"], "all": UNIT + ["top"]}  # suite 이름 -> TB 목록


def build(tb: str, cov: bool) -> bool:                      # TB 하나를 빌드하는 함수 (성공하면 True)
    if cov:  # 코드 커버리지는 xelab 옵션이 필요 -> 짧은 실행으로 빌드
        cmd = SIM + ["run", "--tb", tb, "--cov", "--test", CFG["tbs"][tb]["tests"][0], "--seed", "1"]  # 짧은 run --cov로 커버리지 snapshot 빌드
    else:                                                   # 코드 커버리지가 아니면
        cmd = SIM + ["lint", "--tb", tb]                    # lint로 빌드만
    r = subprocess.run(cmd, cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)  # 출력은 버리고 실행
    return r.returncode != 2                                # 종료 코드 2만 빌드 실패 (1은 테스트 실패)


def run_one(tb: str, test: str, seed: int, timeout: int | None) -> dict:  # (tb, test, seed) 실행 하나를 돌리고 결과를 돌려주는 함수
    cmd = SIM + ["run", "--tb", tb, "--test", test, "--seed", str(seed), "--no-build", "--isolate"]  # 빌드 없이, snapshot 사본으로 격리 실행
    if timeout:                                             # 시간 제한이 있으면
        cmd += ["--timeout", str(timeout)]                  # 인자 추가
    subprocess.run(cmd, cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)  # 출력은 버리고 실행 (결과는 result.json으로 받음)
    rj = ROOT / "out" / tb / "runs" / f"{test}_{seed}" / "result.json"  # 결과 파일 경로
    if rj.exists():                                         # 있으면
        return json.loads(rj.read_text(encoding="utf-8"))   # 읽어서 반환
    return {"tb": tb, "test": test, "seed": seed, "verdict": "NO_RESULT", "ok": False,  # 없으면 NO_RESULT 결과를 만들어 반환
            "reasons": ["sim.py produced no result.json"], "first_errors": [], "duration_s": 0,  # 실패 이유
            "rerun": f"python scripts/sim.py run --tb {tb} --test {test} --seed {seed}"}  # 다시 실행 명령


def write_junit(path: Path, name: str, results: list[dict], build_fail: list[str]) -> tuple[int, int]:  # 회귀 전체를 JUnit XML로 쓰고 (실패 수, XFAIL 수)를 돌려주는 함수
    cases = []                                              # testcase 요소 목록
    for r in results:                                       # 실행 결과마다
        body = ""                                           # testcase 본문
        if not r["ok"]:                                     # 기대와 다르면
            body = (f'<failure message="{escape(r["verdict"] + ": " + "; ".join(r["reasons"]))}">'  # failure 요소 (판정과 이유)
                    f'{escape(chr(10).join(r["first_errors"]) + chr(10) + r["rerun"])}</failure>')  # 첫 오류 줄과 다시 실행 명령
        elif r["verdict"] == "XFAIL":                       # XFAIL이면
            body = f'<skipped message="{escape("XFAIL " + str(r.get("known_fail", "")))}"/>'  # skipped 요소 (known_fail 사유)
        cases.append(f'  <testcase classname="{escape(r["tb"])}" name="{escape(r["test"])}[seed={r["seed"]}]"'  # testcase 요소
                     f' time="{r["duration_s"]}">{body}</testcase>')  # 걸린 시간과 본문
    for tb in build_fail:                                   # 빌드 실패한 TB마다
        cases.append(f'  <testcase classname="{tb}" name="build"><failure message="build failed"/></testcase>')  # build testcase를 실패로 추가
    nfail = sum(not r["ok"] for r in results) + len(build_fail)  # 실패 수 = 기대와 다른 실행 + 빌드 실패
    nxfail = sum(r["verdict"] == "XFAIL" for r in results)  # XFAIL 수
    path.write_text(                                        # 파일 쓰기
        f'<?xml version="1.0" encoding="UTF-8"?>\n<testsuite name="{name}" tests="{len(cases)}" '  # XML 선언과 testsuite 시작
        f'failures="{nfail}" skipped="{nxfail}">\n' + "\n".join(cases) + "\n</testsuite>\n", encoding="utf-8")  # testcase들과 testsuite 닫기
    return nfail, nxfail                                    # 두 개수 반환


def main() -> int:                                          # 진입점
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)  # 인자 파서
    ap.add_argument("--tb", nargs="*", default=[])          # TB 이름 (여러 개 가능)
    ap.add_argument("--suite", choices=sorted(SUITES))      # suite 이름
    ap.add_argument("--tests", nargs="*", help="이 테스트만 실행 (그 TB에 있는 경우)")  # 특정 테스트만
    ap.add_argument("--seeds", type=int, default=1)         # 테스트마다 seed 개수
    ap.add_argument("--first-seed", type=int, default=1)    # 첫 seed (재현용)
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) - 2))  # 병렬 실행 수 (기본: CPU 수 - 2)
    ap.add_argument("--timeout", type=int, help="실행 하나의 타임아웃 (초)")  # 실행 하나의 시간 제한
    ap.add_argument("--cov", action="store_true", help="코드 커버리지 빌드")  # 코드 커버리지
    ap.add_argument("--name", help="out/regress/ 아래 보고서 이름 (기본: suite 이름 또는 'custom')")  # 보고서 이름
    ap.add_argument("--plan", help="회귀 계획 JSON (scripts/ml_regress.py analyze 출력): TB, 테스트, seed 수")  # 계획 파일
    a = ap.parse_args()                                     # 인자 파싱

    plan = json.loads(Path(a.plan).read_text(encoding="utf-8"))["plan"] if a.plan else {}  # TB -> {테스트: seed 수}
    tbs = list(a.tb) + [t for t in SUITES.get(a.suite, []) if t not in a.tb]  # --tb 목록 + suite의 TB (중복 제외)
    if not tbs:                                             # --tb/--suite가 없으면
        tbs = list(plan)                                    # 계획에 있는 TB 전부 (있으면 그 TB만 계획 적용)
    if not tbs:                                             # TB가 하나도 없으면
        ap.error("give --tb or --suite")                    # 오류
    out = ROOT / "out" / "regress" / (a.name or a.suite or ("plan" if plan else "custom"))  # 보고서 디렉터리
    out.mkdir(parents=True, exist_ok=True)                  # 생성
    t0 = time.time()                                        # 시작 시각

    build_fail = [tb for tb in tbs if not build(tb, a.cov)]  # TB마다 차례로 빌드하고 실패한 TB 목록을 모음
    work = []                                               # 실행할 작업 목록
    for tb in tbs:                                          # TB마다
        if tb in build_fail:                                # 빌드 실패한 TB면
            continue                                        # 건너뜀
        tests = CFG["tbs"][tb].get("tests") or [CFG["tbs"][tb].get("default_test")]  # 등록된 테스트 목록 (없으면 기본 테스트)
        if a.tests:                                         # --tests가 있으면
            tests = [t for t in tests if t in a.tests]      # 그 테스트만 남김
        missing = [t for t in tests if tb in plan and t not in plan[tb]]  # 계획보다 나중에 추가된 테스트
        if missing:                                         # 있으면 빠뜨리지 않고 --seeds 수로 돌림
            print(f"WARNING: {tb}: not in plan, running with --seeds {a.seeds}: {' '.join(missing)} "  # 경고
                  f"(re-run scripts/ml_regress.py analyze --save-plan)", flush=True)  # 계획을 다시 만들라는 안내
        for test in tests:                                  # 테스트마다
            n = plan.get(tb, {}).get(test, a.seeds)         # seed 수 (계획에 있으면 계획대로, 없으면 --seeds)
            seeds = [a.first_seed] + [random.randint(1, 2**31 - 1) for _ in range(n - 1)]  # 첫 seed + 랜덤 seed (n - 1)개
            work += [(tb, test, s) for s in seeds]          # (tb, test, seed) 작업 추가

    print(f"regress: {len(work)} runs on {len(tbs)} TBs, {a.jobs} parallel jobs", flush=True)  # 작업 수 안내
    results = []                                            # 결과 목록
    with ThreadPoolExecutor(max_workers=a.jobs) as ex:      # 스레드 풀 생성
        futs = [ex.submit(run_one, tb, test, s, a.timeout) for tb, test, s in work]  # 모든 작업 제출
        for i, f in enumerate(as_completed(futs), 1):       # 끝나는 순서대로
            r = f.result()                                  # 결과 받기
            results.append(r)                               # 결과 저장
            print(f"[{i:3d}/{len(work)}] {r['verdict']:18s} {r['tb']:9s} {r['test']:26s} seed={r['seed']}",  # 진행 상황 한 줄 출력
                  flush=True)                               # 즉시 출력
    results.sort(key=lambda r: (r["tb"], r["test"], r["seed"]))  # TB, 테스트, seed 순으로 정렬

    nfail, nxfail = write_junit(out / "junit.xml", out.name, results, build_fail)  # JUnit XML 쓰기
    (out / "summary.json").write_text(json.dumps(           # summary.json 쓰기
        {"tbs": tbs, "runs": len(results), "fail": nfail, "xfail": nxfail, "build_fail": build_fail,  # TB 목록, 실행 수, 실패 수, XFAIL 수, 빌드 실패
         "elapsed_s": round(time.time() - t0, 1),           # 걸린 시간
         "results": [{k: r.get(k) for k in ("tb", "test", "seed", "verdict", "ok", "reasons", "rerun")}  # 실행마다 핵심 필드만
                     for r in results]}, indent=2), encoding="utf-8")  # 정렬된 결과 순서로

    for r in results:                                       # 결과마다
        if not r["ok"]:                                     # 기대와 다르면
            print(f"FAIL {r['tb']} {r['test']} seed={r['seed']}: {'; '.join(r['reasons'])}\n     {r['rerun']}")  # 실패 정보와 다시 실행 명령 출력
    for tb in build_fail:                                   # 빌드 실패 TB마다
        print(f"BUILD FAIL {tb}: python scripts/sim.py lint --tb {tb}")  # 빌드 실패와 확인 명령 출력
    print(f"\nruns={len(results)} fail={nfail} xfail={nxfail} ({time.time() - t0:.0f}s) -> {out}")  # 최종 요약 줄
    return 0 if nfail == 0 else 1                           # 실패가 없으면 0, 있으면 1


if __name__ == "__main__":                                  # 스크립트로 실행될 때만
    sys.exit(main())                                        # main의 반환값을 종료 코드로
