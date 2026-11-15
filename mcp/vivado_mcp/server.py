#!/usr/bin/env python3
"""
vivado-mcp - dma-uvm 시뮬레이션 흐름을 에이전트에게 제공하는 MCP 서버.

얇은 wrapper입니다: 모든 도구는 Jenkins와 사람이 쓰는 것과 같은 scripts/sim.py 또는
scripts/regress.py를 실행합니다. 에이전트가 보는 결과가 곧 CI가 보는 결과입니다.

안전 규칙 (에이전트에게 맡기지 않고 여기서 강제):
  * tb / test 이름은 verif/sim_cfg.json에 있어야 하고, plusargs/defines는 엄격한 패턴에
    맞아야 합니다. shell에는 아무것도 넘기지 않습니다.
  * 소스 파일을 쓰는 도구는 없습니다. 출력은 out/ 아래에만 씁니다. RTL(HW/)은 읽기 전용입니다.
  * 로그는 out/ 아래 파일만 읽을 수 있고, 걸러낸 일부만 돌려줍니다. 그래서 거대한
    XSim 로그가 에이전트의 컨텍스트를 채우지 않습니다.

실행 (stdio):  mcp/.venv/Scripts/python.exe mcp/vivado_mcp/server.py
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any

from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError  # 메시지가 에이전트에게 전달됨

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "out"
CFG_PATH = ROOT / "verif" / "sim_cfg.json"
SIM = ROOT / "scripts" / "sim.py"
REGRESS = ROOT / "scripts" / "regress.py"
# 시뮬레이션 스크립트는 이 venv가 아니라 시스템 Python으로 실행 (Jenkins와 같음).
PY = sys.executable
_sys_py = Path.home() / "AppData/Local/Programs/Python/Python313/python.exe"
if _sys_py.exists():
    PY = str(_sys_py)

ARG_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(=[A-Za-z0-9_.:+-]*)?$")
SEED_RE = re.compile(r"^(random|\d{1,10})$")
MAX_SYNC_S = 900                 # 동기 도구 호출의 최대 시간
_regressions: dict[str, dict[str, Any]] = {}

server = MCPServer(
    name="vivado-mcp",
    version="1.0.0",
    instructions=(
        "Vivado 2022.2 XSim UVM flow for dma_ip. Start with list_testbenches. "
        "Use run_test for one test/seed and get_log_excerpt to debug a failure. "
        "Use start_regression + regression_status for many runs. "
        "Never modify RTL under HW/: report RTL bugs instead (see list_known_bugs)."
    ),
)


# --------------------------------------------------------------------------- helpers
def _cfg() -> dict:
    return json.loads(CFG_PATH.read_text(encoding="utf-8"))


def _check_tb(tb: str) -> dict:
    tbs = _cfg()["tbs"]
    if tb not in tbs:
        raise ToolError(f"unknown tb '{tb}'. Known: {', '.join(tbs)}")
    return tbs[tb]


def _check_test(tbcfg: dict, test: str | None) -> str:
    tests = tbcfg.get("tests") or [tbcfg.get("default_test")]
    test = test or tbcfg.get("default_test")
    if test not in tests:
        raise ToolError(f"unknown test '{test}' for this tb. Known: {', '.join(t for t in tests if t)}")
    return test


def _check_args(values: list[str] | None, what: str) -> list[str]:
    for v in values or []:
        if not ARG_RE.match(v):
            raise ToolError(f"invalid {what} '{v}' (allowed: NAME or NAME=value, [A-Za-z0-9_.:+-])")
    return list(values or [])


def _run(cmd: list[str], timeout: int) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True,
                          encoding="utf-8", errors="replace", timeout=timeout)


def _tail(text: str, n: int = 15) -> str:
    return "\n".join(text.strip().splitlines()[-n:])


def _safe_out_path(p: Path) -> Path:
    p = p.resolve()
    if OUT.resolve() not in p.parents:
        raise ToolError("path outside out/ is not accessible")
    return p


# --------------------------------------------------------------------------- tools
@server.tool()
def list_testbenches() -> dict:
    """등록된 테스트벤치와 각각의 테스트, 기본 테스트, known-fail(RTL 버그) 항목을 보여 줍니다."""
    out = {}
    for name, t in _cfg()["tbs"].items():
        out[name] = {"desc": t.get("desc", ""), "uvm": t.get("uvm", False),
                     "tests": t.get("tests") or ([t["default_test"]] if t.get("default_test") else []),
                     "default_test": t.get("default_test"),
                     "known_fail": t.get("known_fail", {}),
                     "expect": t.get("expect", "pass")}
    return out


@server.tool()
def lint(tb: str, defines: list[str] | None = None) -> dict:
    """테스트벤치를 시뮬레이션 없이 컴파일하고 elaborate합니다 (xvlog + xelab).
    ok와, 실패했다면 처음 나온 컴파일 에러를 돌려줍니다."""
    _check_tb(tb)
    cmd = [PY, str(SIM), "lint", "--tb", tb]
    for d in _check_args(defines, "define"):
        cmd += ["--define", d]
    r = _run(cmd, 600)
    errs = [l for l in (r.stdout + r.stderr).splitlines() if re.match(r"^\s*(ERROR|FATAL_ERROR):", l)]
    return {"ok": r.returncode == 0, "errors": errs[:20],
            "logs": [str(OUT / tb / "build" / f) for f in ("xvlog.log", "xelab.log")],
            "tail": "" if r.returncode == 0 else _tail(r.stdout)}


@server.tool()
def run_test(tb: str, test: str | None = None, seed: str = "1", plusargs: list[str] | None = None,
             rebuild: bool = True, coverage: bool = False, wave: bool = False,
             timeout_s: int = 600) -> dict:
    """UVM 테스트 하나를 seed 하나로 실행합니다 (seed: 정수 또는 'random').
    Returns the verdict (PASS/FAIL/XFAIL/XPASS), failure reasons, the first UVM errors,
    the log path and the exact command that reproduces the run.
    rebuild=False면 이 tb의 마지막 빌드를 다시 씀 (더 빠름, 소스가 같을 때)."""
    tbcfg = _check_tb(tb)
    test = _check_test(tbcfg, test)
    if not SEED_RE.match(seed):
        raise ToolError("seed must be an integer or 'random'")
    timeout_s = max(30, min(int(timeout_s), MAX_SYNC_S))
    cmd = [PY, str(SIM), "run", "--tb", tb, "--test", test, "--seed", seed, "--timeout", str(timeout_s)]
    for p in _check_args(plusargs, "plusarg"):
        cmd += ["--plusarg", p]
    if not rebuild:
        cmd.append("--no-build")
    if coverage:
        cmd.append("--cov")
    if wave:
        cmd.append("--wave")
    r = _run(cmd, timeout_s + 600)
    if r.returncode == 2:
        return {"verdict": "BUILD_FAIL", "ok": False, "tail": _tail(r.stdout, 25)}
    m = re.search(r"^\[\S+\] tb=\S+ test=\S+ seed=(\d+)", r.stdout, re.M)   # sim.py 판정 줄
    real_seed = m.group(1) if m else seed
    rj = OUT / tb / "runs" / f"{test}_{real_seed}" / "result.json"
    if not rj.exists():
        return {"verdict": "NO_RESULT", "ok": False, "tail": _tail(r.stdout, 25)}
    res = json.loads(rj.read_text(encoding="utf-8"))
    keep = ("tb", "test", "seed", "verdict", "ok", "reasons", "first_errors", "uvm_counts",
            "known_fail", "duration_s", "sim_end_time", "log", "rerun")
    res = {k: res[k] for k in keep if k in res}
    res["first_errors"] = [e[:300] for e in res.get("first_errors", [])[:5]]
    if wave:
        res["wave"] = str(rj.parent / "wave.wdb")
    return res


@server.tool()
def get_log_excerpt(tb: str, test: str, seed: str, pattern: str | None = None,
                    context: int = 2, max_lines: int = 80) -> dict:
    """run.log에서 걸러낸 일부를 돌려줍니다 (파일 전체는 절대 돌려주지 않음).
    기본 필터: UVM_ERROR/UVM_FATAL/SVA/scoreboard/JOB/TEST 줄과 report 요약.
    pattern: 다른 줄을 고를 정규식, 선택 사항 (예: 'AXI_AW|AXI_W')."""
    _check_tb(tb)
    if not SEED_RE.match(seed) or seed == "random":
        raise ToolError("seed must be the integer seed of an existing run")
    log = _safe_out_path(OUT / tb / "runs" / f"{test}_{seed}" / "run.log")
    if not log.exists():
        raise ToolError(f"no log for {tb}/{test}/{seed}. Run it first.")
    rx = re.compile(pattern) if pattern else re.compile(
        r"^(UVM_ERROR|UVM_FATAL)\s+(?!:)|\[(SB_[A-Z_]+|JOB|TEST|COV|AXI_[A-Z0-9_]+|VR_SVA|AXIL_SVA|AXI_SVA)\]"
        r"|^UVM_(ERROR|FATAL|WARNING)\s*:\s*\d+|^ERROR:|FATAL_ERROR")
    lines = log.read_text(encoding="utf-8", errors="replace").splitlines()
    keep: set[int] = set()
    for i, l in enumerate(lines):
        if rx.search(l):
            keep.update(range(max(0, i - context), min(len(lines), i + context + 1)))
    sel = sorted(keep)
    excerpt, prev = [], -2
    for i in sel[: max(1, min(max_lines, 400))]:
        if i != prev + 1:
            excerpt.append(f"... (line {i + 1})")
        excerpt.append(lines[i][:400])
        prev = i
    return {"log": str(log), "total_lines": len(lines), "matched_lines": len(sel),
            "truncated": len(sel) > max_lines, "excerpt": "\n".join(excerpt)}


@server.tool()
def start_regression(suite: str | None = "unit", tbs: list[str] | None = None,
                     tests: list[str] | None = None, seeds: int = 1, jobs: int = 6) -> dict:
    """회귀를 백그라운드에서 시작합니다 (suite: unit|top|all, 또는 tbs를 직접 지정).
    회귀 id를 돌려줍니다. regression_status로 진행 상황을 확인합니다."""
    cfg_tbs = _cfg()["tbs"]
    for t in tbs or []:
        _check_tb(t)
    known_tests = {x for v in cfg_tbs.values() for x in (v.get("tests") or [])}
    for t in tests or []:
        if t not in known_tests:
            raise ToolError(f"unknown test '{t}'")
    if suite not in (None, "unit", "top", "all"):
        raise ToolError("suite must be unit, top or all")
    if not (tbs or suite):
        raise ToolError("give a suite or tbs")
    rid = time.strftime("mcp_%Y%m%d_%H%M%S_") + uuid.uuid4().hex[:4]
    cmd = [PY, str(REGRESS), "--seeds", str(max(1, min(seeds, 50))),
           "--jobs", str(max(1, min(jobs, 8))), "--name", rid]
    if tbs:
        cmd += ["--tb", *tbs]
    if suite:
        cmd += ["--suite", suite]
    if tests:
        cmd += ["--tests", *tests]
    logf = OUT / "regress" / f"{rid}.console.txt"
    logf.parent.mkdir(parents=True, exist_ok=True)
    fh = open(logf, "w", encoding="utf-8")
    proc = subprocess.Popen(cmd, cwd=ROOT, stdout=fh, stderr=subprocess.STDOUT)
    _regressions[rid] = {"proc": proc, "console": logf, "fh": fh, "started": time.time()}
    return {"id": rid, "console": str(logf), "command": " ".join(cmd[1:])}


@server.tool()
def regression_status(id: str) -> dict:
    """start_regression으로 시작한 회귀의 상태: 실행 중이면 진행률,
    끝났으면 집계와 실패한 실행 목록(재실행 명령 포함)."""
    if not re.match(r"^mcp_\d{8}_\d{6}_[0-9a-f]{4}$", id):
        raise ToolError("invalid regression id")
    info = _regressions.get(id)
    console = OUT / "regress" / f"{id}.console.txt"
    summary = OUT / "regress" / id / "summary.json"
    running = bool(info and info["proc"].poll() is None)
    if info and not running and not info["fh"].closed:
        info["fh"].close()
    progress = ""
    if console.exists():
        prog = [l for l in console.read_text(encoding="utf-8", errors="replace").splitlines()
                if l.startswith("[")]
        progress = prog[-1] if prog else ""
    if running or not summary.exists():
        return {"id": id, "state": "running" if running else "unknown", "progress": progress,
                "elapsed_s": round(time.time() - info["started"]) if info else None}
    s = json.loads(summary.read_text(encoding="utf-8"))
    fails = [r for r in s["results"] if not r["ok"]]
    return {"id": id, "state": "done", "runs": s["runs"], "fail": s["fail"], "xfail": s["xfail"],
            "build_fail": s["build_fail"], "elapsed_s": s.get("elapsed_s"),
            "failures": [{k: r[k] for k in ("tb", "test", "seed", "verdict", "reasons", "rerun")}
                         for r in fails[:20]],
            "junit": str(summary.parent / "junit.xml")}


@server.tool()
def coverage_report(tb: str) -> dict:
    """tb의 모든 실행에서 기능 커버리지를 합치고 (coverage=True로 빌드했다면 코드 커버리지도),
    covergroup별 점수와 HTML 보고서 경로를 돌려줍니다."""
    _check_tb(tb)
    r = _run([PY, str(SIM), "cov-report", "--tb", tb], 600)
    rep = OUT / tb / "cov"
    groups = {}
    txt = rep / "func" / "xcrg_func_cov_report.txt"
    if txt.exists():
        # 첫 "CgName," 표 = 모든 covergroup 요약: "<name> ,<score> ,..."
        rows = txt.read_text(encoding="utf-8", errors="replace").splitlines()
        hdr = next((i for i, l in enumerate(rows) if l.strip().startswith("CgName,")), None)
        if hdr is not None:
            for l in rows[hdr + 1:]:
                if not l.strip():
                    if groups:
                        break
                    continue
                cells = [c.strip() for c in l.split(",")]
                try:
                    groups[cells[0]] = float(cells[1])
                except (IndexError, ValueError):
                    break
    return {"ok": r.returncode == 0, "covergroups": groups,
            "func_html": str(rep / "func" / "dashboard.html"),
            "code_html": str(rep / "code" / "dashboard.html") if (rep / "code").exists() else None,
            "tail": _tail(r.stdout, 5)}


@server.tool()
def list_known_bugs() -> dict:
    """검증에서 찾은 RTL 버그(verif/BUGS.md)와, 그 버그를 known_fail로 추적하는 테스트.
    RTL은 읽기 전용이라 보고만 하고, 이 흐름에서 고치지 않습니다."""
    bugs = {}
    md = (ROOT / "verif" / "BUGS.md").read_text(encoding="utf-8")
    for m in re.finditer(r"^## (BUG-\d+): (.+?)$(.*?)(?=^## |\Z)", md, re.M | re.S):
        status = re.search(r"\*\*(?:상태|Status):\*\*\s*(.+)", m.group(3))
        repro = re.search(r"\*\*(?:재현|Reproducer):\*\*\s*`([^`]+)`", m.group(3))
        bugs[m.group(1)] = {"title": m.group(2).strip(),
                            "status": status.group(1).strip() if status else "",
                            "reproducer": repro.group(1) if repro else ""}
    tracked = {}
    for tb, t in _cfg()["tbs"].items():
        for test, why in t.get("known_fail", {}).items():
            bid = (re.match(r"(BUG-\d+)", why) or [None, "?"])[1]
            tracked.setdefault(bid, []).append(f"{tb}/{test}")
    for bid, b in bugs.items():
        b["tracked_by"] = tracked.get(bid, [])
    return bugs


if __name__ == "__main__":
    server.run("stdio")
