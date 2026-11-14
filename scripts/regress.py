#!/usr/bin/env python3
"""
regress.py - run every registered test of the selected TBs over N seeds, in parallel.

  python scripts/regress.py --suite unit --seeds 3
  python scripts/regress.py --suite all  --seeds 2 --jobs 6
  python scripts/regress.py --tb top --tests dma_smoke_test dma_irq_test

Builds each TB once (serially), then runs (tb, test, seed) jobs in a thread pool.
Each run calls `sim.py run --no-build --isolate`, so it takes the same code path as
a single run, but on a private snapshot copy.
The first seed of every test is --first-seed (reproducible). The rest are random.
Writes out/regress/<name>/summary.json and junit.xml.
Exit 0 only if every run matches its expectation (PASS, or XFAIL for known bugs).
"""
from __future__ import annotations

import argparse
import json
import os
import random
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent
SIM = [sys.executable, str(ROOT / "scripts" / "sim.py")]
CFG = json.loads((ROOT / "verif" / "sim_cfg.json").read_text(encoding="utf-8"))
UNIT = [k for k, v in CFG["tbs"].items() if v.get("tests") and k != "top"]
SUITES = {"unit": UNIT, "top": ["top"], "all": UNIT + ["top"]}


def build(tb: str, cov: bool) -> bool:
    if cov:  # code coverage needs xelab options -> build through a short run
        cmd = SIM + ["run", "--tb", tb, "--cov", "--test", CFG["tbs"][tb]["tests"][0], "--seed", "1"]
    else:
        cmd = SIM + ["lint", "--tb", tb]
    r = subprocess.run(cmd, cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return r.returncode != 2


def run_one(tb: str, test: str, seed: int, timeout: int | None) -> dict:
    cmd = SIM + ["run", "--tb", tb, "--test", test, "--seed", str(seed), "--no-build", "--isolate"]
    if timeout:
        cmd += ["--timeout", str(timeout)]
    subprocess.run(cmd, cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    rj = ROOT / "out" / tb / "runs" / f"{test}_{seed}" / "result.json"
    if rj.exists():
        return json.loads(rj.read_text(encoding="utf-8"))
    return {"tb": tb, "test": test, "seed": seed, "verdict": "NO_RESULT", "ok": False,
            "reasons": ["sim.py produced no result.json"], "first_errors": [], "duration_s": 0,
            "rerun": f"python scripts/sim.py run --tb {tb} --test {test} --seed {seed}"}


def write_junit(path: Path, name: str, results: list[dict], build_fail: list[str]) -> tuple[int, int]:
    cases = []
    for r in results:
        body = ""
        if not r["ok"]:
            body = (f'<failure message="{escape(r["verdict"] + ": " + "; ".join(r["reasons"]))}">'
                    f'{escape(chr(10).join(r["first_errors"]) + chr(10) + r["rerun"])}</failure>')
        elif r["verdict"] == "XFAIL":
            body = f'<skipped message="{escape("XFAIL " + str(r.get("known_fail", "")))}"/>'
        cases.append(f'  <testcase classname="{escape(r["tb"])}" name="{escape(r["test"])}[seed={r["seed"]}]"'
                     f' time="{r["duration_s"]}">{body}</testcase>')
    for tb in build_fail:
        cases.append(f'  <testcase classname="{tb}" name="build"><failure message="build failed"/></testcase>')
    nfail = sum(not r["ok"] for r in results) + len(build_fail)
    nxfail = sum(r["verdict"] == "XFAIL" for r in results)
    path.write_text(
        f'<?xml version="1.0" encoding="UTF-8"?>\n<testsuite name="{name}" tests="{len(cases)}" '
        f'failures="{nfail}" skipped="{nxfail}">\n' + "\n".join(cases) + "\n</testsuite>\n", encoding="utf-8")
    return nfail, nxfail


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tb", nargs="*", default=[])
    ap.add_argument("--suite", choices=sorted(SUITES))
    ap.add_argument("--tests", nargs="*", help="only these tests (where the TB has them)")
    ap.add_argument("--seeds", type=int, default=1)
    ap.add_argument("--first-seed", type=int, default=1)
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) - 2))
    ap.add_argument("--timeout", type=int, help="per-run timeout in seconds")
    ap.add_argument("--cov", action="store_true", help="code-coverage build")
    ap.add_argument("--name", help="report name under out/regress/ (default: suite or 'custom')")
    a = ap.parse_args()

    tbs = list(a.tb) + [t for t in SUITES.get(a.suite, []) if t not in a.tb]
    if not tbs:
        ap.error("give --tb or --suite")
    out = ROOT / "out" / "regress" / (a.name or a.suite or "custom")
    out.mkdir(parents=True, exist_ok=True)
    t0 = time.time()

    build_fail = [tb for tb in tbs if not build(tb, a.cov)]
    work = []
    for tb in tbs:
        if tb in build_fail:
            continue
        tests = CFG["tbs"][tb].get("tests") or [CFG["tbs"][tb].get("default_test")]
        if a.tests:
            tests = [t for t in tests if t in a.tests]
        for test in tests:
            seeds = [a.first_seed] + [random.randint(1, 2**31 - 1) for _ in range(a.seeds - 1)]
            work += [(tb, test, s) for s in seeds]

    print(f"regress: {len(work)} runs on {len(tbs)} TBs, {a.jobs} parallel jobs", flush=True)
    results = []
    with ThreadPoolExecutor(max_workers=a.jobs) as ex:
        futs = [ex.submit(run_one, tb, test, s, a.timeout) for tb, test, s in work]
        for i, f in enumerate(as_completed(futs), 1):
            r = f.result()
            results.append(r)
            print(f"[{i:3d}/{len(work)}] {r['verdict']:18s} {r['tb']:9s} {r['test']:26s} seed={r['seed']}",
                  flush=True)
    results.sort(key=lambda r: (r["tb"], r["test"], r["seed"]))

    nfail, nxfail = write_junit(out / "junit.xml", out.name, results, build_fail)
    (out / "summary.json").write_text(json.dumps(
        {"tbs": tbs, "runs": len(results), "fail": nfail, "xfail": nxfail, "build_fail": build_fail,
         "elapsed_s": round(time.time() - t0, 1),
         "results": [{k: r.get(k) for k in ("tb", "test", "seed", "verdict", "ok", "reasons", "rerun")}
                     for r in results]}, indent=2), encoding="utf-8")

    for r in results:
        if not r["ok"]:
            print(f"FAIL {r['tb']} {r['test']} seed={r['seed']}: {'; '.join(r['reasons'])}\n     {r['rerun']}")
    for tb in build_fail:
        print(f"BUILD FAIL {tb}: python scripts/sim.py lint --tb {tb}")
    print(f"\nruns={len(results)} fail={nfail} xfail={nxfail} ({time.time() - t0:.0f}s) -> {out}")
    return 0 if nfail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
