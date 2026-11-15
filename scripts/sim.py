#!/usr/bin/env python3
"""
sim.py - Vivado XSim 시뮬레이션의 단일 진입점.

Jenkins, vivado MCP 서버, 사람이 모두 이 스크립트를 부르므로
로컬에서 본 결과가 CI가 보는 결과와 같습니다.

  python scripts/sim.py list
  python scripts/sim.py lint  --tb rtl
  python scripts/sim.py run   --tb ref_adder_fixed --seed random
  python scripts/sim.py run   --tb top --test dma_smoke_test --seed 1234 --cov --wave
  python scripts/sim.py cov-report --tb ref_adder_fixed

출력 (out/ 아래):
  out/<tb>/build/                 xvlog/xelab 로그 + snapshot
  out/<tb>/runs/<test>_<seed>/    run.log, result.json, junit.xml [, wave.wdb]

종료 코드: 0 = 결과가 기대와 맞음 (PASS, 또는 "expect": "fail"이면 XFAIL),
           1 = 테스트 결과 불일치, 2 = 빌드/도구 오류.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from xml.sax.saxutils import escape

# 한글 출력이 Jenkins/MCP(UTF-8로 읽음)에서 깨지지 않도록 출력 인코딩을 UTF-8로 고정
for _s in (sys.stdout, sys.stderr):
    if hasattr(_s, "reconfigure"):
        _s.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parent.parent
CFG_PATH = ROOT / "verif" / "sim_cfg.json"
OUT = ROOT / "out"


# --------------------------------------------------------------------------- #
# 도구 찾기
# --------------------------------------------------------------------------- #
def vivado_bin(cfg: dict) -> Path:
    """XILINX_VIVADO 환경 변수 -> PATH -> 기본 설치 위치 순으로 찾음."""
    env = os.environ.get("XILINX_VIVADO")
    if env and (Path(env) / "bin").is_dir():
        return Path(env) / "bin"
    found = shutil.which("xvlog")
    if found:
        return Path(found).parent
    default = Path(f"C:/Xilinx/Vivado/{cfg.get('vivado_version', '2022.2')}/bin")
    if default.is_dir():
        return default
    sys.exit("ERROR: Vivado not found. Set XILINX_VIVADO or add Vivado/bin to PATH.")


def tool(cfg: dict, name: str) -> str:
    b = vivado_bin(cfg)
    exe = b / (name + ".bat") if os.name == "nt" else b / name
    return str(exe)


# --------------------------------------------------------------------------- #
# filelist(.f) 파싱: 파일, +incdir+, +define+, 중첩 -f, // 또는 # 주석
# --------------------------------------------------------------------------- #
def parse_filelist(path: Path, acc=None) -> dict:
    acc = acc or {"files": [], "incdirs": [], "defines": []}
    base = path.parent
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("//", 1)[0].strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("+incdir+"):
            for d in line[len("+incdir+"):].split("+"):
                if d:
                    acc["incdirs"].append(str((base / d).resolve()))
        elif line.startswith("+define+"):
            acc["defines"] += [d for d in line[len("+define+"):].split("+") if d]
        elif line.startswith("-f "):
            parse_filelist((base / line[3:].strip()).resolve(), acc)
        else:
            p = (base / line).resolve()
            if not p.exists():
                sys.exit(f"ERROR: {path.name}: file not found: {p}")
            acc["files"].append(str(p))
    return acc


# --------------------------------------------------------------------------- #
# 보조 함수
# --------------------------------------------------------------------------- #
def load_cfg() -> dict:
    return json.loads(CFG_PATH.read_text(encoding="utf-8"))


def get_tb(cfg: dict, name: str) -> dict:
    if name not in cfg["tbs"]:
        sys.exit(f"ERROR: unknown tb '{name}'. Known: {', '.join(cfg['tbs'])}")
    return cfg["tbs"][name]


def win_cmdline(cmd: list[str]) -> str:
    """Windows의 Vivado 도구는 .bat wrapper라서, cmd.exe가 따옴표 없는 인자를
    '=' ',' ';'에서 나눔 (예: UVM_TESTNAME=foo -> 'UVM_TESTNAME' 'foo'). 그래서 따옴표로 감쌈."""
    out = []
    for c in cmd:
        # 역슬래시 경로는 XSim이 만드는 C 문자열 안에 들어가 ("\U", "\D" ...)
        # 코드 커버리지 elaboration을 깨뜨림. 슬래시(/)는 어디서나 동작함.
        c = c.replace("\\", "/")
        out.append(f'"{c}"' if re.search(r'[\s=,;&()^]', c) and not c.startswith('"') else c)
    return " ".join(out)


def run_tool(cmd: list[str], cwd: Path, timeout: int | None = None) -> int:
    line = win_cmdline(cmd) if os.name == "nt" else cmd
    print(">>", line if isinstance(line, str) else " ".join(line), flush=True)
    try:
        p = subprocess.run(line, cwd=cwd, timeout=timeout)
        return p.returncode
    except subprocess.TimeoutExpired:
        print(f"ERROR: timeout after {timeout}s", flush=True)
        return 124


def count_errors(log: Path) -> list[str]:
    if not log.exists():
        return [f"missing log {log}"]
    txt = log.read_text(encoding="utf-8", errors="replace")
    return [l for l in txt.splitlines() if re.match(r"^\s*(ERROR|FATAL_ERROR):", l)]


# --------------------------------------------------------------------------- #
# 빌드 (xvlog + xelab)
# --------------------------------------------------------------------------- #
def build(cfg: dict, tb_name: str, defines: list[str], cov: bool, wave: bool) -> Path:
    tb = get_tb(cfg, tb_name)
    bdir = OUT / tb_name / "build"
    if bdir.exists():
        shutil.rmtree(bdir, ignore_errors=True)
    bdir.mkdir(parents=True, exist_ok=True)

    fl = {"files": [], "incdirs": [], "defines": []}
    for f in tb["filelists"]:
        parse_filelist(ROOT / f, fl)
    all_defs = fl["defines"] + tb.get("defines", []) + defines

    cmd = [tool(cfg, "xvlog"), "--sv", "--log", str(bdir / "xvlog.log")]
    if tb.get("uvm"):
        cmd += ["-L", "uvm"]
    for d in fl["incdirs"]:
        cmd += ["-i", d]
    for d in all_defs:
        cmd += ["-d", d]
    cmd += fl["files"]
    rc = run_tool(cmd, bdir)
    errs = count_errors(bdir / "xvlog.log")
    if rc != 0 or errs:
        print("\n".join(errs[:20]))
        print(f"BUILD FAILED (xvlog) - see {bdir / 'xvlog.log'}")
        sys.exit(2)

    snap = f"{tb_name}_snap"
    cmd = [tool(cfg, "xelab"), tb["top"], "-s", snap,
           "--timescale", "1ns/1ps", "--log", str(bdir / "xelab.log")]
    if tb.get("uvm"):
        cmd += ["-L", "uvm"]
    cmd += ["--debug", "typical" if wave else "off"]
    if cov:
        cmd += ["--cc_type", "sbct", "--cc_dir", str(bdir / "codecov"), "--cc_db", snap,
                "--cov_db_dir", str(bdir / "funccov"), "--cov_db_name", snap]
    rc = run_tool(cmd, bdir)
    errs = count_errors(bdir / "xelab.log")
    if rc != 0 or errs:
        print("\n".join(errs[:20]))
        print(f"BUILD FAILED (xelab) - see {bdir / 'xelab.log'}")
        sys.exit(2)

    meta = {"tb": tb_name, "snapshot": snap, "defines": all_defs, "cov": cov, "wave": wave,
            "files": fl["files"], "time": time.strftime("%Y-%m-%d %H:%M:%S")}
    (bdir / "build.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
    print(f"BUILD OK: {tb_name} -> {snap}")
    return bdir


# --------------------------------------------------------------------------- #
# 실행 (xsim) + 결과 판정
# --------------------------------------------------------------------------- #
UVM_CNT = re.compile(r"^\s*(UVM_INFO|UVM_WARNING|UVM_ERROR|UVM_FATAL)\s*:\s*(\d+)\s*$", re.M)
UVM_MSG = re.compile(r"^(UVM_ERROR|UVM_FATAL)\s+(?!:).*$", re.M)  # 요약 줄 "UVM_ERROR :  N"은 건너뜀


def judge(log: Path, uvm: bool, rc: int) -> dict:
    txt = log.read_text(encoding="utf-8", errors="replace") if log.exists() else ""
    counts = {k: int(v) for k, v in UVM_CNT.findall(txt)}  # 마지막 요약을 사용
    tool_errs = [l for l in txt.splitlines() if re.match(r"^\s*(ERROR|FATAL_ERROR):", l)]
    msg_lines = [m.group(0) for m in UVM_MSG.finditer(txt)]
    reasons = []
    if rc == 124:
        reasons.append("timeout")
    elif rc != 0:
        reasons.append(f"xsim exit code {rc}")
    if tool_errs:
        reasons.append(f"{len(tool_errs)} simulator ERROR lines")
    if uvm:
        if "UVM Report Summary" not in txt:
            reasons.append("no UVM Report Summary (sim did not finish cleanly)")
        if counts.get("UVM_ERROR", 0):
            reasons.append(f"UVM_ERROR={counts['UVM_ERROR']}")
        if counts.get("UVM_FATAL", 0):
            reasons.append(f"UVM_FATAL={counts['UVM_FATAL']}")
    m = re.search(r"Time:\s*([\d.]+\s*\w+)", txt)
    return {
        "status": "FAIL" if reasons else "PASS",
        "reasons": reasons,
        "uvm_counts": counts,
        "first_errors": msg_lines[:10] or tool_errs[:10],
        "n_uvm_error_lines": len(msg_lines),
        "sim_end_time": m.group(1) if m else None,
    }


def write_junit(path: Path, suite: str, case: str, res: dict, dur: float):
    body = ""
    if res["status"] == "FAIL" and not res.get("expected_fail"):
        msg = escape("; ".join(res["reasons"]))
        detail = escape("\n".join(res["first_errors"]))
        body = f'<failure message="{msg}">{detail}</failure>'
    elif res.get("expected_fail"):
        body = f'<system-out>{escape("XFAIL: " + "; ".join(res["reasons"]))}</system-out>'
    fails = 1 if body.startswith("<failure") else 0
    path.write_text(
        f'<?xml version="1.0" encoding="UTF-8"?>\n'
        f'<testsuite name="{escape(suite)}" tests="1" failures="{fails}" time="{dur:.2f}">\n'
        f'  <testcase classname="{escape(suite)}" name="{escape(case)}" time="{dur:.2f}">{body}</testcase>\n'
        f'</testsuite>\n', encoding="utf-8")


def run(cfg: dict, a) -> int:
    tb = get_tb(cfg, a.tb)
    bdir = OUT / a.tb / "build"
    if not a.no_build or not (bdir / "build.json").exists():
        build(cfg, a.tb, a.define, a.cov, a.wave)
    meta = json.loads((bdir / "build.json").read_text(encoding="utf-8"))

    rc = 0
    n = max(1, a.repeat)
    for i in range(n):
        if a.seed == "random" or (n > 1 and i > 0):
            seed = random.randint(1, 2**31 - 1)
        else:
            seed = int(a.seed)
        rc = max(rc, run_one(cfg, a, tb, bdir, meta, seed))
    return rc


def run_one(cfg: dict, a, tb: dict, bdir: Path, meta: dict, seed: int) -> int:
    test = a.test or tb.get("default_test", "none")
    rdir = OUT / a.tb / "runs" / f"{test}_{seed}"
    if rdir.exists():
        shutil.rmtree(rdir, ignore_errors=True)
    rdir.mkdir(parents=True)
    log = rdir / "run.log"

    cmd = [tool(cfg, "xsim"), meta["snapshot"], "--log", str(log), "--sv_seed", str(seed)]
    if tb.get("uvm"):
        cmd += ["--testplusarg", f"UVM_TESTNAME={test}",
                "--testplusarg", f"UVM_VERBOSITY={a.verbosity}"]
    for p in a.plusarg:
        cmd += ["--testplusarg", p]
    # 기능 커버리지(covergroup)는 항상 수집, 실행마다 DB 하나
    cmd += ["--cov_db_dir", str(rdir / "funccov"), "--cov_db_name", f"{test}_{seed}"]
    if a.wave:
        if not meta["wave"]:
            print("WARN: snapshot built without --wave; rebuild with --wave for waveforms")
        tcl = rdir / "wave.tcl"
        tcl.write_text("log_wave -recursive *\nrun all\nquit\n", encoding="utf-8")
        cmd += ["--wdb", str(rdir / "wave.wdb"), "--tclbatch", str(tcl)]
    else:
        cmd += ["--runall"]

    # --isolate: snapshot 개인 사본을 써서 병렬 실행끼리 xsim.dir를 공유하지 않게 함
    cwd = bdir
    if a.isolate:
        shutil.copytree(bdir / "xsim.dir", rdir / "xsim.dir")
        cwd = rdir
    t0 = time.time()
    rc = run_tool(cmd, cwd, timeout=a.timeout or cfg.get("default_timeout_s", 600))
    dur = time.time() - t0
    if a.isolate:
        shutil.rmtree(rdir / "xsim.dir", ignore_errors=True)

    res = judge(log, tb.get("uvm", False), rc)
    # 예상된 실패: TB 전체("expect": "fail") 또는 테스트별로 추적 중인 RTL 버그
    known = tb.get("known_fail", {}).get(test)
    expect_fail = tb.get("expect") == "fail" or known is not None
    if known:
        res["known_fail"] = known
    res["expected_fail"] = expect_fail and res["status"] == "FAIL"
    ok = (res["status"] == "PASS") != expect_fail
    verdict = ("XFAIL" if res["expected_fail"] else
               "XPASS(unexpected)" if expect_fail else res["status"])
    res.update({"tb": a.tb, "test": test, "seed": seed, "verdict": verdict, "ok": ok,
                "duration_s": round(dur, 2), "log": str(log),
                "rerun": f"python scripts/sim.py run --tb {a.tb} --test {test} --seed {seed}"
                         + "".join(f" --define {d}" for d in a.define)
                         + "".join(f" --plusarg {q}" for q in a.plusarg)})
    (rdir / "result.json").write_text(json.dumps(res, indent=2), encoding="utf-8")
    write_junit(rdir / "junit.xml", a.tb, f"{test}[seed={seed}]", res, dur)

    print("=" * 72)
    print(f"[{verdict}] tb={a.tb} test={test} seed={seed} ({dur:.1f}s)")
    if known:
        print(f"   known-fail: {known}")
    for r in res["reasons"]:
        print(f"   - {r}")
    for e in res["first_errors"][:3]:
        print(f"   > {e[:200]}")
    print(f"   log   : {log}")
    print(f"   rerun : {res['rerun']}")
    print("=" * 72)
    return 0 if ok else 1


# --------------------------------------------------------------------------- #
# 커버리지 보고서 (xcrg)
# --------------------------------------------------------------------------- #
def cov_report(cfg: dict, a) -> int:
    bdir = OUT / a.tb / "build"
    meta_p = bdir / "build.json"
    if not meta_p.exists():
        sys.exit(f"ERROR: no build for {a.tb}. Run: sim.py run --tb {a.tb}")
    meta = json.loads(meta_p.read_text())
    snap = meta["snapshot"]
    rep = OUT / a.tb / "cov"
    # xcrg는 기존 텍스트 보고서를 바꾸지 않고 뒤에 덧붙이므로, 옛 점수가 파일
    # 맨 위에 남음: 항상 빈 보고서 디렉터리에서 시작
    shutil.rmtree(rep, ignore_errors=True)
    rep.mkdir(parents=True, exist_ok=True)
    # 참고: xcrg.bat는 성공해도 127로 끝나므로 (2022.2) 로그/출력으로 판정.
    def xcrg_ok(log: Path, out_dir: Path) -> bool:
        txt = log.read_text(encoding="utf-8", errors="replace") if log.exists() else ""
        bad = "could not be completed" in txt or re.search(r"^\s*ERROR", txt, re.M)
        return out_dir.exists() and not bad

    ok = True
    if meta["cov"]:
        run_tool([tool(cfg, "xcrg"), "-report_format", "html",
                  "-cc_dir", str(bdir / "codecov"), "-cc_db", snap,
                  "-cc_report", str(rep / "code"), "-log", str(rep / "xcrg_code.log")], bdir)
        ok &= xcrg_ok(rep / "xcrg_code.log", rep / "code")
    else:
        print("INFO: build has no code coverage (use run --cov); functional coverage only")
    # 모든 실행의 기능 커버리지를 합침 (covergroup이 있을 때만 존재)
    runs = sorted((OUT / a.tb / "runs").glob("*/funccov/xsim.covdb"))
    if runs:
        lst = rep / "funccov_dbs.txt"
        lst.write_text("\n".join(p.as_posix() for p in runs), encoding="utf-8")
        run_tool([tool(cfg, "xcrg"), "-report_format", "all", "-file", str(lst),   # html + 텍스트
                  "-merge_dir", str(rep / "merged"), "-report_dir", str(rep / "func"),
                  "-log", str(rep / "xcrg_func.log")], bdir)
        ok &= xcrg_ok(rep / "xcrg_func.log", rep / "func")
    else:
        print("INFO: no functional coverage DBs (no covergroups yet)")
    print(f"Coverage report {'OK' if ok else 'FAILED'}: {rep}")
    return 0 if ok else 2


# --------------------------------------------------------------------------- #
def main() -> int:
    cfg = load_cfg()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list", help="등록된 테스트벤치 목록")

    p = sub.add_parser("lint", help="컴파일 + elaborate만")
    p.add_argument("--tb", required=True)
    p.add_argument("--define", action="append", default=[])

    p = sub.add_parser("run", help="빌드 (--no-build가 아니면) 후 테스트/seed 하나 시뮬레이션")
    p.add_argument("--tb", required=True)
    p.add_argument("--test")
    p.add_argument("--seed", default="1")
    p.add_argument("--define", action="append", default=[])
    p.add_argument("--plusarg", action="append", default=[])
    p.add_argument("--verbosity", default="UVM_LOW")
    p.add_argument("--timeout", type=int)
    p.add_argument("--cov", action="store_true")
    p.add_argument("--wave", action="store_true")
    p.add_argument("--no-build", action="store_true")
    p.add_argument("--repeat", type=int, default=1, help="seed N개 실행 (첫째 = --seed, 나머지는 랜덤)")
    p.add_argument("--isolate", action="store_true", help="snapshot 개인 사본에서 실행 (병렬 실행에 안전)")

    p = sub.add_parser("cov-report", help="코드 + 기능 커버리지 HTML 생성")
    p.add_argument("--tb", required=True)

    a = ap.parse_args()
    if a.cmd == "list":
        for k, v in cfg["tbs"].items():
            print(f"{k:18s} {v.get('desc', '')}")
        return 0
    if a.cmd == "lint":
        build(cfg, a.tb, a.define, cov=False, wave=False)
        return 0
    if a.cmd == "run":
        return run(cfg, a)
    if a.cmd == "cov-report":
        return cov_report(cfg, a)
    return 2


if __name__ == "__main__":
    sys.exit(main())
