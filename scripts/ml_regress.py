#!/usr/bin/env python3
"""
ml_regress.py - 회귀 결과로 커버리지 모델을 학습해, 같은 커버리지를 더 적은 실행으로 얻는 회귀 계획을 만듭니다.

  python scripts/ml_regress.py extract --from out/regress/ml_data/summary.json   # 실행마다 bin 적중표 추출
  python scripts/ml_regress.py analyze                                         # 학습, 교차 검증, 계획 생성
  python scripts/ml_regress.py analyze --save-plan verif/regress_plan.json    # 계획을 저장소에 저장 (CI smoke가 사용)
  python scripts/regress.py --plan verif/regress_plan.json                     # 만든 계획으로 회귀
  python scripts/ml_regress.py check --summary out/regress/unit/summary.json out/regress/top/summary.json  # 목표 bin 확인

방법
  1. 데이터: 실행(tb, test, seed)마다 기능 커버리지 DB를 xcrg로 풀어, 어떤 bin을 몇 번 쳤는지 기록합니다.
  2. 모델: (테스트, bin)마다 "seed 하나로 돌렸을 때 이 bin을 칠 확률" p를 Beta-Bernoulli 사후 평균으로
     추정합니다. p = (적중한 실행 수 + a) / (실행 수 + a + b). 한 번도 못 친 조합은 0에 가까운 값이 됩니다.
  3. 계획: 테스트마다 실행 횟수 n_t를 정합니다. bin b를 놓칠 확률은 prod_t (1 - p_tb)^n_t 이고,
     매 단계 "놓칠 확률 합의 감소량 / 실행 시간"이 가장 큰 테스트에 실행 하나를 더합니다 (greedy).
     놓칠 확률의 합이 1 - target 아래가 되면 멈춥니다 (union bound라 보수적).
  4. 검증: seed를 테스트마다 반으로 나눠 절반으로 학습하고, 나머지 절반(학습에 안 쓴 seed)에서 계획대로
     실행을 뽑아 100% 커버리지에 도달하는 비율을 셉니다. 같은 실행 수의 무작위 선택, CI smoke(36회),
     nightly full(테스트당 seed 5개)과 비교합니다.

결과: out/ml/runs.jsonl (데이터), out/ml/plan.json (계획), out/ml/report.json, out/ml/report.md
"""
from __future__ import annotations                          # 타입 힌트를 문자열로 지연 평가

import argparse                                             # 명령줄 인자
import json                                                 # 데이터와 결과 저장
import random                                               # 데이터 분할, 표본 추출
import re                                                   # xcrg 보고서 파싱
import subprocess                                           # xcrg 실행
import sys                                                  # 종료 코드, 출력 인코딩
import tempfile                                             # xcrg 임시 보고서 디렉터리
import time                                                 # 시각
from collections import defaultdict                         # 묶음 사전
from concurrent.futures import ThreadPoolExecutor           # xcrg 병렬 실행
from pathlib import Path                                    # 경로 처리

for _s in (sys.stdout, sys.stderr):                         # 표준 출력과 오류 출력마다
    _s.reconfigure(encoding="utf-8", errors="replace")      # UTF-8로 (Windows 코드페이지 949 대비)

ROOT = Path(__file__).resolve().parent.parent               # 저장소 루트
OUT = ROOT / "out" / "ml"                                   # 결과 디렉터리
CFG = json.loads((ROOT / "verif" / "sim_cfg.json").read_text(encoding="utf-8"))  # TB 설정
XCRG = "C:/Xilinx/Vivado/2022.2/bin/xcrg.bat"               # xcrg (sim.py와 같은 Vivado)
PRIOR_A, PRIOR_B = 0.05, 1.0                                # Beta prior: 못 본 조합은 거의 0, 본 조합은 데이터가 지배
TOP_SMOKE = ["dma_reg_reset_test", "dma_reg_bitbash_test", "dma_smoke_test",  # Jenkinsfile의 smoke top 테스트
             "dma_small_test", "dma_irq_test", "dma_aw_backpressure_test"]   # (같은 목록 유지)


# --------------------------------------------------------------------------- #
# 1. 데이터 추출
# --------------------------------------------------------------------------- #
def parse_report(txt: str) -> dict[str, int]:               # xcrg 텍스트 보고서 -> {bin 키: 적중 수}
    bins: dict[str, int] = {}                               # 결과
    table = None                                            # 지금 읽는 coverpoint 표 이름
    mode = None                                             # 'bins' 섹션 안이면 True
    seen: set[str] = set()                                  # 이미 읽은 표 이름
    zero_w: set[str] = set()                                # weight 0인 coverpoint/cross (목표가 아닌 참고용)
    inst = None                                             # 요약 섹션의 현재 인스턴스
    for line in txt.splitlines():                           # 요약 섹션에서 weight 읽기
        m = re.match(r"\s*Instance (\S+) (?:Cross )?Cover Point Details", line)  # 인스턴스 요약 시작
        if m:                                               # 찾으면
            inst = m[1]                                     # 기억
            continue                                        # 다음 줄
        f = [x.strip() for x in line.split(",")]            # 쉼표로 나눔
        if inst and len(f) >= 8 and f[2].isdigit() and f[7].isdigit():  # 이름, tag, 기대 bin 수, ..., weight
            if int(f[7]) == 0:                              # weight 0이면
                zero_w.add(f"{inst}.{f[0]}")                # 제외 목록에 추가
    for line in txt.splitlines():                           # 줄마다
        m = re.match(r"\s*(?:Cross )?Cover Point Table for Inst : (.+?), Variable :, (\S+)", line)  # 표 시작
        if m:                                               # 새 표면
            base = f"{m[1].strip()}.{m[2]}"                 # 인스턴스.변수
            # xcrg 2022.2는 covergroup의 두 번째 cross 표에 첫 번째 cross의 이름과 내용을 그대로 다시 찍음
            # (예: x_dir_4k 자리에 x_dir_len). 같은 이름이 또 나오면 그 표는 버림.
            table = None if base in seen or base in zero_w else base  # 중복 표와 weight 0 표는 읽지 않음
            seen.add(base)                                  # 기록
            mode = None                                     # 섹션 초기화
            continue                                        # 다음 줄
        s = line.strip()                                    # 앞뒤 공백 제거
        if s.endswith("Uncovered bins") or s.endswith("Covered bins"):  # bin 목록 섹션 시작
            mode = True                                     # 목록 읽기 시작
            continue                                        # 다음 줄
        if not s:                                           # 빈 줄이면
            mode = None if mode == "data" else mode         # 데이터 뒤의 빈 줄은 섹션 끝
            continue                                        # 다음 줄
        if mode and table and "Hit Count" in s:             # 열 이름 줄
            mode = "data"                                   # 다음 줄부터 데이터
            continue                                        # 다음 줄
        if mode == "data" and table:                        # 데이터 줄이면
            f = [x.strip() for x in s.split(",")]           # 쉼표로 나눔 (끝에 빈 칸 하나)
            f = f[:-1] if f and f[-1] == "" else f          # 끝 빈 칸 제거
            if any("*" in x or "(" in x for x in f[:-2]):   # 못 친 cross bin 묶음 ("one x *", "(one mid ) x rd")은 개별 bin이 아님
                continue                                    # 건너뜀 (친 bin만 목표로 쓰므로 영향 없음)
            if len(f) >= 3 and f[-2].isdigit():             # 이름..., 적중 수, AtLeast
                bins[f"{table}:{'x'.join(f[:-2])}"] = int(f[-2])  # bin 키 = 표:이름 (cross는 x로 연결)
    return bins                                             # 결과


def extract_one(tb: str, test: str, seed: int) -> dict | None:  # 실행 하나의 bin 적중표
    db = ROOT / "out" / tb / "runs" / f"{test}_{seed}" / "funccov" / "xsim.covdb"  # 기능 커버리지 DB
    rj = db.parent.parent / "result.json"                   # 실행 결과
    if not db.exists() or not rj.exists():                  # 없으면 (covergroup 없는 TB, 실행 실패)
        return None                                         # 건너뜀
    res = json.loads(rj.read_text(encoding="utf-8"))        # 판정과 시간
    bins = None                                             # bin 적중표
    for _ in range(3):                                      # xcrg가 가끔 보고서 없이 끝나므로 (CI #25에서 47회 중 2회) 3번까지 시도
        with tempfile.TemporaryDirectory() as td:           # 임시 보고서 디렉터리
            subprocess.run(f'"{XCRG}" -report_format text -dir "{db}" -report_dir "{td}/r" -log "{td}/x.log"',  # 단일 DB 보고서
                           shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)  # xcrg.bat는 성공해도 127
            rep = Path(td) / "r" / "xcrg_func_cov_report.txt"  # 텍스트 보고서
            if rep.exists():                                # 보고서가 있으면
                bins = parse_report(rep.read_text(encoding="utf-8", errors="replace"))  # 파싱
                break                                       # 성공
    if bins is None:                                        # 3번 모두 실패하면
        return None                                         # 건너뜀 (호출한 쪽이 실패 목록에 기록)
    return {"tb": tb, "test": test, "seed": seed, "verdict": res.get("verdict"),  # 실행 정보
            "duration_s": res.get("duration_s", 0), "bins": bins}  # 시간, bin 적중표


def extract(a) -> int:                                      # extract 명령
    summ = json.loads(Path(a.src).read_text(encoding="utf-8"))  # 회귀 summary.json
    work = [(r["tb"], r["test"], r["seed"]) for r in summ["results"]]  # 실행 목록
    OUT.mkdir(parents=True, exist_ok=True)                  # 결과 디렉터리
    with ThreadPoolExecutor(max_workers=a.jobs) as ex:      # 병렬 xcrg
        rows = [r for r in ex.map(lambda w: extract_one(*w), work) if r]  # 결과 모음 (없는 것 제외)
    with open(OUT / "runs.jsonl", "w", encoding="utf-8") as f:  # 데이터 파일
        for r in rows:                                      # 실행마다
            f.write(json.dumps(r) + "\n")                   # 한 줄에 하나
    per_tb = defaultdict(int)                               # TB별 실행 수
    for r in rows:                                          # 실행마다
        per_tb[r["tb"]] += 1                                # 세기
    print(f"extract: {len(rows)}/{len(work)} runs with coverage -> {OUT / 'runs.jsonl'}  {dict(per_tb)}")  # 요약
    return 0 if rows else 1                                 # 하나도 없으면 실패


# --------------------------------------------------------------------------- #
# 2. 모델과 계획
# --------------------------------------------------------------------------- #
def fit(runs: list[dict], bins: list[str]) -> dict:         # (테스트, bin) 적중 확률 학습
    by_t = defaultdict(list)                                # 테스트 -> 실행 목록
    for r in runs:                                          # 실행마다
        by_t[r["test"]].append(r)                           # 묶기
    p, cost = {}, {}                                        # 확률표, 실행 시간
    for t, rs in by_t.items():                              # 테스트마다
        n = len(rs)                                         # 실행 수
        p[t] = {b: (sum(r["bins"].get(b, 0) > 0 for r in rs) + PRIOR_A) / (n + PRIOR_A + PRIOR_B)  # 사후 평균
                for b in bins}                              # bin마다
        cost[t] = max(1.0, sum(r["duration_s"] for r in rs) / n)  # 평균 실행 시간 (초)
    return {"p": p, "cost": cost}                           # 모델


def plan(model: dict, bins: list[str], target: float, min_per_test: int, cap: int = 400) -> dict[str, int]:  # greedy 계획
    p, cost = model["p"], model["cost"]                     # 확률표, 비용
    n = {t: min_per_test for t in p}                        # 테스트마다 기본 실행 수
    miss = {b: 1.0 for b in bins}                           # bin마다 놓칠 확률
    for t, k in n.items():                                  # 기본 실행 반영
        for b in bins:                                      # bin마다
            miss[b] *= (1 - p[t][b]) ** k                   # k번 모두 놓칠 확률
    while sum(miss.values()) > 1 - target and sum(n.values()) < cap:  # 목표에 못 미치면
        best = max(p, key=lambda t: sum(miss[b] * p[t][b] for b in bins) / cost[t])  # 시간당 기대 이득 최대
        n[best] += 1                                        # 실행 하나 추가
        for b in bins:                                      # bin마다
            miss[b] *= 1 - p[best][b]                       # 놓칠 확률 갱신
    return {t: k for t, k in n.items() if k}                # 0회 테스트는 뺌


def covers(sample: list[dict], bins: set[str]) -> float:    # 실행 묶음이 bin을 얼마나 덮는지 (0~1)
    hit = set()                                             # 친 bin
    for r in sample:                                        # 실행마다
        hit.update(b for b, h in r["bins"].items() if h > 0)  # 친 bin 추가
    return len(bins & hit) / len(bins)                      # 비율


def draw(pool: dict[str, list[dict]], counts: dict[str, int], rng: random.Random) -> list[dict]:  # 계획대로 실행 뽑기
    out = []                                                # 뽑은 실행
    for t, k in counts.items():                             # 테스트마다
        if pool.get(t):                                     # 그 테스트의 실행이 있으면
            src = pool[t]                                   # 검증용 실행 (서로 다른 seed)
            out += rng.sample(src, k) if k <= len(src) else rng.choices(src, k=k)  # 겹치지 않게 뽑고, 모자라면 복원 추출
    return out                                              # 결과


# --------------------------------------------------------------------------- #
# 3. 분석 (교차 검증 + 최종 계획)
# --------------------------------------------------------------------------- #
def analyze(a) -> int:                                      # analyze 명령
    rows = [json.loads(l) for l in (OUT / "runs.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()]  # 데이터
    rng = random.Random(a.seed)                             # 재현 가능한 난수
    tbs = sorted({r["tb"] for r in rows})                   # TB 목록
    data = {}                                               # TB -> (실행 목록, 목표 bin, 전체 bin)
    for tb in tbs:                                          # TB마다
        rs = [r for r in rows if r["tb"] == tb]             # 그 TB의 실행
        allb = sorted({b for r in rs for b in r["bins"]})   # 보고서에 나온 모든 bin
        cov = sorted({b for r in rs for b, h in r["bins"].items() if h > 0})  # 한 번이라도 친 bin = 목표
        data[tb] = (rs, cov, allb)                          # 저장

    # 기준 계획들 (테스트 -> 실행 수)
    def base(tb: str, kind: str) -> dict[str, int]:         # 기준 계획
        tests = sorted({r["test"] for r in data[tb][0]})    # 이 TB의 테스트
        if kind == "full":                                  # nightly full
            return {t: 5 for t in tests}                    # 테스트당 seed 5개
        if tb == "top":                                     # smoke의 top
            return {t: 1 for t in tests if t in TOP_SMOKE}  # 정해진 6개, seed 1개
        return {t: 1 for t in tests}                        # smoke의 unit: 모든 테스트 seed 1개

    stats = defaultdict(lambda: defaultdict(list))          # 방식 -> 지표 -> 값 목록
    for split in range(a.splits):                           # 데이터 분할마다
        trials = defaultdict(lambda: [1.0] * a.trials)      # 방식 -> 시도별 "모든 TB 100%" 여부
        runs_used = defaultdict(int)                        # 방식 -> 총 실행 수
        for tb in tbs:                                      # TB마다
            rs, cov, _ = data[tb]                           # 데이터
            train, hold = [], defaultdict(list)             # 학습용, 검증용
            by_t = defaultdict(list)                        # 테스트 -> 실행
            for r in rs:                                    # 실행마다
                by_t[r["test"]].append(r)                   # 묶기
            for t, lst in by_t.items():                     # 테스트마다
                lst = lst[:]                                # 복사
                rng.shuffle(lst)                            # 섞기
                h = len(lst) // 2                           # 반
                train += lst[:h]                            # 앞 절반은 학습
                hold[t] = lst[h:]                           # 뒤 절반은 검증
            model = fit(train, cov)                         # 학습
            plans = {"ml_safe": plan(model, cov, a.target, 1),  # 모든 테스트 1회 이상 + 커버리지용 추가
                     "ml_cov": plan(model, cov, a.target, 0),   # 커버리지만 보고 고른 최소 계획
                     "smoke": base(tb, "smoke"), "full": base(tb, "full")}  # 기준
            n_safe = sum(plans["ml_safe"].values())         # ml_safe 실행 수
            tests = sorted(by_t)                            # 테스트 목록
            covset = set(cov)                               # 목표 bin
            for name, pl in plans.items():                  # 방식마다
                runs_used[name] += sum(pl.values())         # 실행 수 합
                for i in range(a.trials):                   # 시도마다
                    c = covers(draw(hold, pl, rng), covset)  # 검증 seed로 커버리지
                    stats[name][f"cov_{tb}"].append(c)      # TB별 커버리지
                    trials[name][i] *= (c == 1.0)           # 모든 TB 100%인지
            runs_used["random_same_budget"] += n_safe       # 같은 실행 수 무작위
            for i in range(a.trials):                       # 시도마다
                pl = defaultdict(int)                       # 무작위 계획
                for _ in range(n_safe):                     # 실행 수만큼
                    pl[rng.choice(tests)] += 1              # 테스트를 무작위로 고름
                c = covers(draw(hold, pl, rng), covset)     # 커버리지
                stats["random_same_budget"][f"cov_{tb}"].append(c)  # 기록
                trials["random_same_budget"][i] *= (c == 1.0)  # 모든 TB 100%인지
        for name in trials:                                 # 방식마다
            stats[name]["p_full_cov"].append(sum(trials[name]) / a.trials)  # 100% 도달 비율
            stats[name]["runs"].append(runs_used[name])     # 실행 수

    avg = lambda v: sum(v) / len(v)                         # 평균
    methods = ["full", "smoke", "ml_safe", "ml_cov", "random_same_budget"]  # 표 순서
    cv = {m: {"runs": round(avg(stats[m]["runs"]), 1), "p_full_cov": round(avg(stats[m]["p_full_cov"]), 3),  # 실행 수, 100% 비율
              "mean_cov": {tb: round(100 * avg(stats[m][f"cov_{tb}"]), 2) for tb in tbs}} for m in methods}  # TB별 평균 커버리지

    # 최종 계획: 모든 데이터로 학습
    final, rare, value = {}, [], {}                         # 계획, 드문 bin, 테스트 기여도
    for tb in tbs:                                          # TB마다
        rs, cov, allb = data[tb]                            # 데이터
        model = fit(rs, cov)                                # 전체 데이터로 학습
        final[tb] = plan(model, cov, a.target, 1)           # 안전한 계획
        for b in cov:                                       # 목표 bin마다
            bt = max(model["p"], key=lambda t: model["p"][t][b])  # 이 bin을 가장 잘 치는 테스트
            if model["p"][bt][b] < a.rare:                  # 그래도 확률이 낮으면
                rare.append({"tb": tb, "bin": b, "best_test": bt, "p_per_run": round(model["p"][bt][b], 3)})  # 드문 bin
        for t in model["p"]:                                # 테스트마다
            only = [b for b in cov if model["p"][t][b] > 0.5 and all(model["p"][u][b] < 0.05 for u in model["p"] if u != t)]  # 이 테스트만 치는 bin
            value[f"{tb}/{t}"] = {"expected_bins_per_run": round(sum(model["p"][t].values()), 2),  # 실행당 기대 bin 수
                                  "unique_bins": len(only), "cost_s": round(model["cost"][t], 1)}  # 고유 bin, 시간
        holes = sorted(set(allb) - set(cov))                # 아무도 못 친 bin
        if holes:                                           # 있으면
            rare += [{"tb": tb, "bin": b, "best_test": None, "p_per_run": 0.0} for b in holes]  # 구멍으로 기록

    n_final = sum(sum(v.values()) for v in final.values())  # 최종 계획 실행 수
    plan_doc = {"generated": time.strftime("%Y-%m-%d %H:%M:%S"), "target": a.target,  # 생성 시각, 목표
                "model": f"Beta-Bernoulli (a={PRIOR_A}, b={PRIOR_B}), greedy expected-coverage per second",  # 모델 설명
                "data_runs": len(rows), "runs": n_final, "plan": final,  # 데이터 수, 실행 수, 계획
                "target_bins": {tb: data[tb][1] for tb in tbs}}  # TB별 목표 bin (check 명령이 씀)
    (OUT / "plan.json").write_text(json.dumps(plan_doc, indent=2), encoding="utf-8")  # 계획 저장
    if a.save_plan:                                         # 저장소에 둘 위치가 있으면
        Path(a.save_plan).write_text(json.dumps(plan_doc, indent=2) + "\n", encoding="utf-8")  # 같은 내용 저장 (CI가 읽음)
    report = {"data_runs": len(rows), "tbs": {tb: {"bins": len(data[tb][2]), "target_bins": len(data[tb][1]),  # TB별 bin 수
                                                   "runs": len(data[tb][0])} for tb in tbs},  # TB별 실행 수
              "splits": a.splits, "trials": a.trials, "target": a.target, "cv": cv,  # 검증 설정과 결과
              "rare_bins": rare, "test_value": value, "plan_runs": n_final}  # 드문 bin, 테스트 가치, 계획 크기
    (OUT / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")  # 보고서 저장

    md = ["# ML 회귀 최적화 결과", "",                      # Markdown 보고서
          f"데이터: 실행 {len(rows)}회, TB {len(tbs)}개. 검증: seed를 반으로 나눈 분할 {a.splits}번 x 추출 {a.trials}번.", "",  # 설정
          "| 방식 | 실행 수 | 모든 TB 100% 도달 비율 | " + " | ".join(tbs) + " |",  # 표 머리
          "|---|---|---|" + "---|" * len(tbs)]              # 구분선
    for m in methods:                                       # 방식마다
        md.append(f"| {m} | {cv[m]['runs']} | {cv[m]['p_full_cov']:.3f} | " + " | ".join(f"{cv[m]['mean_cov'][tb]:.2f}" for tb in tbs) + " |")  # 한 줄
    md += ["", f"최종 계획 (전체 데이터 학습, target {a.target}): 실행 {n_final}회 -> `out/ml/plan.json`", ""]  # 계획 크기
    for tb in tbs:                                          # TB마다
        md.append(f"- {tb}: " + ", ".join(f"{t} x{k}" for t, k in sorted(final[tb].items())))  # 테스트별 횟수
    md += ["", f"## 드문 bin (실행당 적중 확률 < {a.rare})", ""]  # 드문 bin
    md += [f"- {r['tb']} `{r['bin']}`: {r['best_test'] or '없음 (구멍)'} p={r['p_per_run']}" for r in rare] or ["- 없음"]  # 목록
    (OUT / "report.md").write_text("\n".join(md) + "\n", encoding="utf-8")  # 저장
    print("\n".join(md))                                    # 화면 출력
    return 0                                                # 성공


# --------------------------------------------------------------------------- #
# 4. 확인 (CI): 계획대로 돈 회귀가 목표 bin을 모두 채웠는지
# --------------------------------------------------------------------------- #
def check(a) -> int:                                        # check 명령
    doc = json.loads(Path(a.plan).read_text(encoding="utf-8"))  # 계획 (목표 bin 포함)
    target = {tb: set(b) for tb, b in doc.get("target_bins", {}).items()}  # TB -> 목표 bin
    work = []                                               # 확인할 실행
    for sp in a.summary:                                    # 회귀 summary.json마다
        work += [(r["tb"], r["test"], r["seed"]) for r in json.loads(Path(sp).read_text(encoding="utf-8"))["results"]]  # 실행 목록
    with ThreadPoolExecutor(max_workers=a.jobs) as ex:      # 병렬 xcrg
        got = list(ex.map(lambda w: extract_one(*w), work))  # 실행별 bin 적중표 (실패는 None)
    rows = [r for r in got if r]                            # 읽은 실행
    unread = [f"{tb}/{t}_{sd}" for (tb, t, sd), r in zip(work, got) if r is None]  # 커버리지를 못 읽은 실행
    hit = defaultdict(set)                                  # TB -> 친 bin
    for r in rows:                                          # 실행마다
        hit[r["tb"]].update(b for b, h in r["bins"].items() if h > 0)  # 친 bin 모음
    res, ok = {}, True                                      # 결과, 전체 통과 여부
    for tb in sorted(set(hit) & set(target)):               # 이번에 돌았고 목표가 있는 TB마다
        miss = sorted(target[tb] - hit[tb])                 # 못 친 목표 bin
        res[tb] = {"covered": len(target[tb]) - len(miss), "target": len(target[tb]),  # 친 수, 목표 수
                   "pct": round(100 * (1 - len(miss) / len(target[tb])), 2), "missing": miss}  # 비율, 못 친 bin
        ok &= not miss                                      # 하나라도 못 치면 실패
        print(f"{tb:8s} {res[tb]['covered']:3d}/{res[tb]['target']:<3d} {res[tb]['pct']:6.2f}%  " +  # TB별 한 줄
              ("OK" if not miss else "MISSING " + " ".join(miss)))  # 못 친 bin
    tot_c = sum(r["covered"] for r in res.values())         # 전체 친 수
    tot_t = sum(r["target"] for r in res.values())          # 전체 목표 수
    if unread:                                              # 못 읽은 실행이 있으면 (그만큼 bin이 덜 잡혀 INCOMPLETE 쪽으로만 기움)
        print(f"WARNING: coverage not read for {len(unread)} run(s): {' '.join(unread)}")  # 경고
    print(f"plan coverage: {tot_c}/{tot_t} bins ({len(rows)}/{len(work)} runs read) -> {'PASS' if ok else 'INCOMPLETE'}")  # 요약
    OUT.mkdir(parents=True, exist_ok=True)                  # 결과 디렉터리
    (OUT / "check.json").write_text(json.dumps({"ok": ok, "covered": tot_c, "target": tot_t,  # 결과 저장 (CI 보관)
                                                "runs": len(rows), "runs_total": len(work), "unread": unread,  # 읽은 수, 전체 수, 못 읽은 실행
                                                "tbs": res}, indent=2), encoding="utf-8")  # TB별 상세
    return 0 if ok else 1                                   # 모두 채우면 0


def main() -> int:                                          # 진입점
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)  # 인자 파서
    sub = ap.add_subparsers(dest="cmd", required=True)      # 하위 명령
    p = sub.add_parser("extract", help="회귀 결과에서 실행별 bin 적중표 추출")  # extract
    p.add_argument("--from", dest="src", default=str(ROOT / "out" / "regress" / "ml_data" / "summary.json"))  # summary.json
    p.add_argument("--jobs", type=int, default=6)           # xcrg 병렬 수
    p = sub.add_parser("analyze", help="학습, 교차 검증, 계획 생성")  # analyze
    p.add_argument("--target", type=float, default=0.95)   # 100% 커버리지 도달 목표 확률
    p.add_argument("--splits", type=int, default=20)        # 데이터 분할 횟수
    p.add_argument("--trials", type=int, default=200)       # 분할마다 추출 횟수
    p.add_argument("--rare", type=float, default=0.3)       # 드문 bin 기준
    p.add_argument("--seed", type=int, default=1)           # 난수 seed
    p.add_argument("--save-plan", help="계획을 이 경로에도 저장 (예: verif/regress_plan.json, CI가 사용)")  # 저장소용 사본
    p = sub.add_parser("check", help="회귀 결과가 계획의 목표 bin을 모두 채웠는지 확인 (CI)")  # check
    p.add_argument("--plan", default=str(ROOT / "verif" / "regress_plan.json"))  # 계획 파일
    p.add_argument("--summary", nargs="+", required=True, help="regress.py summary.json (여러 개 가능)")  # 회귀 결과
    p.add_argument("--jobs", type=int, default=6)           # xcrg 병렬 수
    a = ap.parse_args()                                     # 인자 파싱
    return {"extract": extract, "analyze": analyze, "check": check}[a.cmd](a)  # 명령 실행


if __name__ == "__main__":                                  # 스크립트로 실행될 때만
    sys.exit(main())                                        # main의 반환값을 종료 코드로
