#!/usr/bin/env python3
"""
vivado-mcp - dma-uvm 시뮬레이션 흐름을 에이전트에게 제공하는 MCP 서버.

얇은 wrapper입니다: 모든 도구는 Jenkins와 사람이 쓰는 것과 같은 scripts/ 아래 스크립트를 실행합니다.
에이전트가 보는 결과가 곧 CI가 보는 결과입니다.

안전 규칙 (에이전트에게 맡기지 않고 여기서 강제):
  * tb / test 이름은 verif/sim_cfg.json에 있어야 하고, plusargs/defines/신호 경로는 엄격한 패턴에 맞아야
    합니다. shell에는 아무것도 넘기지 않습니다.
  * 소스 파일을 쓰는 도구는 없습니다. 출력은 out/ 아래에만 씁니다. RTL(HW/)은 읽기 전용입니다.
  * 로그는 out/ 아래 파일만 읽고, 걸러낸 일부만 돌려줍니다.

worktree: 모든 도구가 workspace 인자를 받습니다. 비우면 이 저장소, 주면 이 저장소의 git worktree여야 하고,
  그 안의 scripts/와 out/을 씁니다 (서브에이전트가 worktree에서 일해도 결과가 섞이지 않음).
잠금: 같은 (workspace, TB)의 빌드와 실행은 out/mcp/locks/<tb>.lock으로 하나씩만 돕니다.
작업 상태: 백그라운드 회귀는 out/mcp/jobs/<id>.json에 남아 서버를 다시 띄워도 확인과 취소가 됩니다.

실행 (stdio):  mcp/.venv/Scripts/python.exe mcp/vivado_mcp/server.py
"""
from __future__ import annotations

import contextlib
import json
import os
import re
import subprocess
import sys
import time
import tomllib
import uuid
from pathlib import Path
from typing import Any, Iterator

from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError

ROOT = Path(__file__).resolve().parents[2]                  # 이 서버가 있는 저장소 (주 작업 트리)
sys.path.insert(0, str(ROOT / "scripts"))                   # 출력 설정을 바꾸지 않는 모듈만 가져옴
import vcd as vcdlib                                        # noqa: E402  VCD 파서 (scripts/vcd.py)
import xcrg_report                                          # noqa: E402  커버리지 보고서 파서 (scripts/xcrg_report.py)
from common import kill_pid_tree, pid_alive                 # noqa: E402  프로세스 확인/종료 (scripts/common.py)

# 시뮬레이션 스크립트는 이 venv가 아니라 시스템 Python으로 실행 (Jenkins와 같음)
PY = sys.executable
_sys_py = Path.home() / "AppData/Local/Programs/Python/Python313/python.exe"
if _sys_py.exists():
    PY = str(_sys_py)
ARG_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(=[A-Za-z0-9_.:+-]*)?$")   # plusarg / define
SEED_RE = re.compile(r"^(random|\d{1,10})$")
NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")             # 회귀 이름, ledger id, gate 단계
HDL_RE = re.compile(r"^/[A-Za-z0-9_/\[\]*.]+$")             # 신호 추적할 HDL 객체
MAX_SYNC_S = 900                                            # 동기 실행 최대 시간
LOCK_WAIT_S = 900                                           # 잠금 대기 최대 시간
JOBS = ROOT / "out" / "mcp" / "jobs"                        # 백그라운드 작업 상태 (주 작업 트리에 모음)
_procs: dict[str, subprocess.Popen] = {}                    # 이 서버가 띄운 작업 (좀비 정리용)


def _git_common(p: Path) -> Path | None:                    # git 공통 폴더 (worktree는 주 저장소의 .git)
    r = subprocess.run(["git", "rev-parse", "--git-common-dir"], cwd=p, capture_output=True, text=True)
    if r.returncode != 0:
        return None
    c = Path(r.stdout.strip())
    return (c if c.is_absolute() else p / c).resolve()


ROOT_COMMON = _git_common(ROOT)

server = MCPServer(
    name="vivado-mcp",
    version="2.0.0",
    instructions=(
        "Vivado 2022.2 XSim UVM flow for dma_ip. Start with list_testbenches. "
        "Use run_test for one test/seed, get_log_excerpt to debug a failure, trace_signals to see signal "
        "values in a time window. Use start_regression + regression_status (cancel_job to stop) for many runs. "
        "Judge completion with run_gate, check_inventory and signoff, not by reading logs. "
        "Every tool takes workspace: leave empty for the main checkout, or pass the path of a git worktree "
        "of this repository. Never modify RTL under HW/: report RTL bugs instead (see list_known_bugs)."
    ),
)


# --------------------------------------------------------------------------- 작업 폴더, 검사, 실행
def _ws(workspace: str | None) -> Path:                     # 작업 폴더 확인
    if not workspace:
        return ROOT
    p = Path(workspace).expanduser().resolve()
    if not p.is_dir() or _git_common(p) != ROOT_COMMON:
        raise ToolError(f"workspace '{workspace}' is not this repository or one of its git worktrees")
    return p


def _cfg(ws: Path) -> dict:
    return json.loads((ws / "verif" / "sim_cfg.json").read_text(encoding="utf-8"))


def _check_tb(ws: Path, tb: str) -> dict:
    tbs = _cfg(ws)["tbs"]
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


def _name(v: str, what: str) -> str:
    if not NAME_RE.match(v or ""):
        raise ToolError(f"invalid {what} '{v}' (allowed: [A-Za-z0-9_-], up to 64)")
    return v


def _run(ws: Path, cmd: list[str], timeout: int) -> subprocess.CompletedProcess:  # 실행 (시간 초과면 트리 종료)
    p = subprocess.Popen(cmd, cwd=ws, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                         encoding="utf-8", errors="replace")
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        kill_pid_tree(p.pid)
        out, err = p.communicate()
        raise ToolError(f"timed out after {timeout}s: {' '.join(cmd[1:])}")
    return subprocess.CompletedProcess(cmd, p.returncode, out, err)


def _script(ws: Path, name: str) -> str:                    # 그 작업 폴더의 스크립트 (브랜치마다 다를 수 있음)
    return str(ws / "scripts" / name)


def _tail(text: str, n: int = 15) -> str:
    return "\n".join(text.strip().splitlines()[-n:])


def _safe_out_path(ws: Path, p: Path) -> Path:
    p = p.resolve()
    if (ws / "out").resolve() not in p.parents:
        raise ToolError("path outside out/ is not accessible")
    return p


# --------------------------------------------------------------------------- 잠금
def _lock_path(ws: Path, tb: str) -> Path:
    return ws / "out" / "mcp" / "locks" / f"{tb}.lock"


def _acquire(ws: Path, tb: str, owner: str, wait_s: int = LOCK_WAIT_S) -> Path:
    """(workspace, tb) 잠금. 파일을 O_EXCL로 만들어 프로세스 사이에서도 하나만 가짐.
    주인 프로세스가 죽은 잠금은 지우고 다시 시도. wait_s 동안 못 얻으면 ToolError."""
    path = _lock_path(ws, tb)
    path.parent.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    while True:
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            with os.fdopen(fd, "w") as f:
                json.dump({"pid": os.getpid(), "owner": owner, "since": time.time()}, f)
            return path
        except FileExistsError:
            try:
                info = json.loads(path.read_text(encoding="utf-8") or "{}")
            except (OSError, ValueError):
                info = {}
            if info and not pid_alive(info.get("pid", -1)):  # 주인이 죽은 잠금
                with contextlib.suppress(OSError):
                    path.unlink()
                continue
            if time.time() - t0 > wait_s:
                raise ToolError(f"tb '{tb}' is busy in this workspace ({info.get('owner')}); try again later")
            time.sleep(1)


def _release(path: Path, owner: str | None = None) -> None:
    with contextlib.suppress(OSError, ValueError):
        if owner is None or json.loads(path.read_text(encoding="utf-8")).get("owner") == owner:
            path.unlink()


@contextlib.contextmanager
def _locked(ws: Path, tbs: list[str], owner: str) -> Iterator[None]:
    held = []
    try:
        for tb in sorted(set(tbs)):                         # 항상 같은 순서로 잡아 교착을 피함
            held.append(_acquire(ws, tb, owner))
        yield
    finally:
        for p in held:
            _release(p)


def _suite_tbs(ws: Path, suite: str | None, tbs: list[str] | None) -> list[str]:  # 회귀가 쓰는 TB
    cfg = _cfg(ws)["tbs"]
    unit = [k for k, v in cfg.items() if v.get("tests") and k != "top"]
    picked = {"unit": unit, "top": ["top"], "all": unit + ["top"]}.get(suite or "", [])
    return sorted(set(picked) | set(tbs or []))


# --------------------------------------------------------------------------- 백그라운드 작업
def _job_path(jid: str) -> Path:
    if not re.match(r"^mcp_\d{8}_\d{6}_[0-9a-f]{4}$", jid):
        raise ToolError("invalid job id")
    return JOBS / f"{jid}.json"


def _job_load(jid: str) -> dict:
    p = _job_path(jid)
    if not p.exists():
        raise ToolError(f"no such job {jid}")
    return json.loads(p.read_text(encoding="utf-8"))


def _job_save(job: dict) -> None:
    JOBS.mkdir(parents=True, exist_ok=True)
    _job_path(job["id"]).write_text(json.dumps(job, indent=2), encoding="utf-8")


def _spawn_detached(cmd: list[str], ws: Path, fh) -> subprocess.Popen:  # MCP 서버와 분리해 띄움
    """회귀를 서버에서 최대한 떼어 띄움. Windows: 새 프로세스 그룹 + 콘솔 분리 + job object 이탈 시도. POSIX: 새 세션.
    stdin은 서버의 MCP stdio 파이프를 물려받지 않게 막음.
    한계: mcp 클라이언트(Windows)는 서버를 KILL_ON_JOB_CLOSE job에 넣고 이탈을 허용하지 않아, 클라이언트가
    연결을 닫으면 회귀도 같이 끝남. 그때 상태는 'interrupted'로 남고 regression_status가 재실행 명령을 돌려줌."""
    kw: dict[str, Any] = {"cwd": ws, "stdin": subprocess.DEVNULL, "stdout": fh, "stderr": subprocess.STDOUT}
    if os.name != "nt":
        return subprocess.Popen(cmd, start_new_session=True, **kw)
    base = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS
    try:
        return subprocess.Popen(cmd, creationflags=base | 0x01000000, **kw)  # CREATE_BREAKAWAY_FROM_JOB
    except OSError:                                         # job이 이탈을 허용하지 않으면
        return subprocess.Popen(cmd, creationflags=base, **kw)


def _job_finish_locks(job: dict) -> None:                   # 끝난 작업의 잠금 해제
    ws = Path(job["workspace"])
    for tb in job.get("tbs", []):
        _release(_lock_path(ws, tb), owner=job["id"])


# --------------------------------------------------------------------------- 도구: 조회
@server.tool()
def list_testbenches(workspace: str = "") -> dict:
    """등록된 테스트벤치와 각각의 테스트, 기본 테스트, known-fail(RTL 버그) 항목을 보여 줍니다."""
    out = {}
    for name, t in _cfg(_ws(workspace))["tbs"].items():
        out[name] = {"desc": t.get("desc", ""), "uvm": t.get("uvm", False),
                     "tests": t.get("tests") or ([t["default_test"]] if t.get("default_test") else []),
                     "default_test": t.get("default_test"), "known_fail": t.get("known_fail", {}),
                     "expect": t.get("expect", "pass")}
    return out


@server.tool()
def list_known_bugs(workspace: str = "") -> dict:
    """검증에서 찾은 RTL 버그와 노트(verif/plan.toml bugs, 설명은 verif/BUGS.md), 그 버그를 known_fail로
    추적하는 테스트, 그리고 아직 확인하지 않은 가설(hypotheses). RTL은 읽기 전용이라 보고만 합니다."""
    ws = _ws(workspace)
    md = (ws / "verif" / "BUGS.md").read_text(encoding="utf-8")
    with open(ws / "verif" / "plan.toml", "rb") as f:
        plan = tomllib.load(f)
    bugs = {}
    for b in plan.get("bugs", []):
        sec = re.search(rf"^## {re.escape(b['id'])}:.*?$(.*?)(?=^## |\Z)", md, re.M | re.S)
        repro = re.search(r"\*\*(?:재현|Reproducer):\*\*\s*`([^`]+)`", sec.group(1)) if sec else None
        bugs[b["id"]] = {"kind": b.get("kind"), "status": b.get("status"), "title": b.get("title"),
                         "known_fail": b.get("known_fail", []), "waiver": b.get("waiver", ""),
                         "reproducer": repro.group(1) if repro else ""}
    hyps = {h["id"]: {"title": h["title"], "status": h["status"], "evidence": h.get("evidence", []),
                      "test": h.get("test", ""), "bug": h.get("bug", "")} for h in plan.get("hypotheses", [])}
    return {"bugs": bugs, "hypotheses": hyps}


# --------------------------------------------------------------------------- 도구: 빌드, 실행, 로그
@server.tool()
def lint(tb: str, defines: list[str] | None = None, workspace: str = "") -> dict:
    """테스트벤치를 시뮬레이션 없이 컴파일하고 elaborate합니다 (xvlog + xelab).
    ok와, 실패했다면 처음 나온 컴파일 에러를 돌려줍니다."""
    ws = _ws(workspace)
    _check_tb(ws, tb)
    cmd = [PY, _script(ws, "sim.py"), "lint", "--tb", tb]
    for d in _check_args(defines, "define"):
        cmd += ["--define", d]
    with _locked(ws, [tb], f"lint {tb}"):
        r = _run(ws, cmd, 600)
    errs = [l for l in (r.stdout + r.stderr).splitlines() if re.match(r"^\s*(ERROR|FATAL_ERROR):", l)]
    return {"ok": r.returncode == 0, "errors": errs[:20], "workspace": str(ws),
            "logs": [str(ws / "out" / tb / "build" / f) for f in ("xvlog.log", "xelab.log")],
            "tail": "" if r.returncode == 0 else _tail(r.stdout)}


@server.tool()
def run_test(tb: str, test: str | None = None, seed: str = "1", plusargs: list[str] | None = None,
             rebuild: bool = True, coverage: bool = False, wave: bool = False,
             timeout_s: int = 600, workspace: str = "") -> dict:
    """UVM 테스트 하나를 seed 하나로 실행합니다 (seed: 정수 또는 'random').
    판정(PASS/FAIL/XFAIL/XPASS), 실패 이유, 처음 나온 에러, 로그 경로, 이 실행을 그대로 재현하는 명령을
    돌려줍니다. rebuild=False면 마지막 빌드를 쓰되, 소스가 바뀌었으면 sim.py가 알아서 다시 빌드합니다."""
    ws = _ws(workspace)
    tbcfg = _check_tb(ws, tb)
    test = _check_test(tbcfg, test)
    if not SEED_RE.match(seed):
        raise ToolError("seed must be an integer or 'random'")
    timeout_s = max(30, min(int(timeout_s), MAX_SYNC_S))
    cmd = [PY, _script(ws, "sim.py"), "run", "--tb", tb, "--test", test, "--seed", seed, "--timeout", str(timeout_s)]
    for p in _check_args(plusargs, "plusarg"):
        cmd += ["--plusarg", p]
    cmd += [x for x, on in (("--no-build", not rebuild), ("--cov", coverage), ("--wave", wave)) if on]
    with _locked(ws, [tb], f"run_test {tb}/{test}"):        # 실행 중에 다른 호출이 빌드를 지우지 않게
        r = _run(ws, cmd, timeout_s + 600)
    if r.returncode == 2:
        return {"verdict": "BUILD_FAIL", "ok": False, "tail": _tail(r.stdout, 25)}
    m = re.search(r"^\[\S+\] tb=\S+ test=\S+ seed=(\d+)", r.stdout, re.M)
    rj = ws / "out" / tb / "runs" / f"{test}_{m.group(1) if m else seed}" / "result.json"
    if not rj.exists():
        return {"verdict": "NO_RESULT", "ok": False, "tail": _tail(r.stdout, 25)}
    res = json.loads(rj.read_text(encoding="utf-8"))
    keep = ("tb", "test", "seed", "verdict", "ok", "reasons", "first_errors", "uvm_counts",
            "known_fail", "duration_s", "sim_end_time", "log", "rerun", "provenance")
    res = {k: res[k] for k in keep if k in res}
    res["first_errors"] = [e[:300] for e in res.get("first_errors", [])[:5]]
    if wave:
        res["wave"] = str(rj.parent / "wave.wdb")
    return res


def _find_log(ws: Path, tb: str, test: str, seed: str, group: str | None) -> Path:  # 실행 폴더 찾기
    runs = ws / "out" / tb / "runs"
    if group:
        return runs / _name(group, "group") / f"{test}_{seed}" / "run.log"
    direct = runs / f"{test}_{seed}" / "run.log"
    if direct.exists():
        return direct
    found = sorted(runs.glob(f"*/{test}_{seed}/run.log"), key=lambda p: p.stat().st_mtime)  # 회귀 실행 폴더
    return found[-1] if found else direct


@server.tool()
def get_log_excerpt(tb: str, test: str, seed: str, pattern: str | None = None, context: int = 2,
                    max_lines: int = 80, group: str | None = None, workspace: str = "") -> dict:
    """run.log에서 걸러낸 일부를 돌려줍니다 (파일 전체는 돌려주지 않음).
    기본 필터: UVM_ERROR/UVM_FATAL/SVA/scoreboard/JOB/TEST 줄, XSim Error/Fatal 줄, report 요약.
    pattern: 다른 줄을 고를 정규식 (예: 'AXI_AW|AXI_W'). group: 회귀 이름 (비우면 단일 실행, 없으면
    가장 최근 회귀의 같은 test/seed)."""
    ws = _ws(workspace)
    _check_tb(ws, tb)
    if not SEED_RE.match(seed) or seed == "random":
        raise ToolError("seed must be the integer seed of an existing run")
    log = _safe_out_path(ws, _find_log(ws, tb, test, seed, group))
    if not log.exists():
        raise ToolError(f"no log for {tb}/{test}/{seed}. Run it first.")
    rx = re.compile(pattern) if pattern else re.compile(
        r"^(UVM_ERROR|UVM_FATAL)\s+(?!:)|\[(SB_[A-Z_]+|JOB|TEST|COV|AXI_[A-Z0-9_]+|VR_SVA|AXIL_SVA|AXI_SVA)\]"
        r"|^UVM_(ERROR|FATAL|WARNING)\s*:\s*\d+|^(ERROR|Error|Fatal):|FATAL_ERROR")
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
def trace_signals(tb: str, objects: list[str], test: str | None = None, seed: str = "1",
                  t_from_ns: float = 0.0, t_to_ns: float = 1000.0, signals: list[str] | None = None,
                  max_changes: int = 300, workspace: str = "") -> dict:
    """테스트 하나를 다시 돌리며 HDL 객체(objects, 예: ['/tb_skid/dut/*'])의 값을 VCD로 남기고,
    t_from_ns..t_to_ns 구간의 값 변화를 텍스트로 돌려줍니다. 가설 확인과 실패 분류용입니다.
    signals: 결과에서 볼 신호 이름 (끝 이름 또는 전체 경로, 비우면 전부). debug 빌드가 필요하면 다시 빌드합니다."""
    ws = _ws(workspace)
    tbcfg = _check_tb(ws, tb)
    test = _check_test(tbcfg, test)
    if not SEED_RE.match(seed) or seed == "random":
        raise ToolError("seed must be an integer (trace a reproducible run)")
    if not objects or any(not HDL_RE.match(o) for o in objects):
        raise ToolError("objects must be HDL paths like /tb_skid/dut/* or /tb_dma/dut/u_wdma/w_state")
    cmd = [PY, _script(ws, "sim.py"), "run", "--tb", tb, "--test", test, "--seed", seed, "--group", "trace"]
    for o in objects:
        cmd += ["--trace", o]
    with _locked(ws, [tb], f"trace_signals {tb}/{test}"):
        r = _run(ws, cmd, MAX_SYNC_S + 600)
    vcd_path = ws / "out" / tb / "runs" / "trace" / f"{test}_{seed}" / "trace.vcd"
    if not vcd_path.exists():
        return {"ok": False, "tail": _tail(r.stdout, 25)}
    res = vcdlib.parse(vcd_path.read_text(encoding="utf-8", errors="replace"), t_from_ns, t_to_ns, signals)
    verdict = re.search(r"^\[(\S+)\] tb=", r.stdout, re.M)
    return {"ok": True, "verdict": verdict.group(1) if verdict else None, "vcd": str(vcd_path),
            "window_ns": [t_from_ns, t_to_ns], "signals": sorted(res["signals"]),
            "changes": len(res["changes"]), "text": vcdlib.as_text(res, max(10, min(max_changes, 2000)))}


# --------------------------------------------------------------------------- 도구: 회귀 (백그라운드)
@server.tool()
def start_regression(suite: str | None = "unit", tbs: list[str] | None = None, tests: list[str] | None = None,
                     seeds: int = 1, jobs: int = 6, plan: bool = False, workspace: str = "") -> dict:
    """회귀를 백그라운드에서 시작합니다 (suite: unit|top|all, 또는 tbs를 직접 지정).
    plan=True면 ML 회귀 계획(verif/regress_plan.json)대로 테스트마다 seed 수를 정합니다 (CI smoke와 같음).
    작업 id를 돌려줍니다. regression_status로 확인하고 cancel_job으로 멈춥니다. 회귀가 도는 동안 그 TB들은
    같은 workspace에서 잠깁니다."""
    ws = _ws(workspace)
    cfg_tbs = _cfg(ws)["tbs"]
    for t in tbs or []:
        _check_tb(ws, t)
    known_tests = {x for v in cfg_tbs.values() for x in (v.get("tests") or [])}
    for t in tests or []:
        if t not in known_tests:
            raise ToolError(f"unknown test '{t}'")
    if suite not in (None, "unit", "top", "all"):
        raise ToolError("suite must be unit, top or all")
    if not (tbs or suite):
        raise ToolError("give a suite or tbs")
    jid = time.strftime("mcp_%Y%m%d_%H%M%S_") + uuid.uuid4().hex[:4]
    cmd = [PY, _script(ws, "regress.py"), "--seeds", str(max(1, min(seeds, 50))),
           "--jobs", str(max(1, min(jobs, 8))), "--name", jid]
    cmd += ["--tb", *tbs] if tbs else []
    cmd += ["--suite", suite] if suite else []
    cmd += ["--tests", *tests] if tests else []
    cmd += ["--plan", "verif/regress_plan.json"] if plan else []
    locked_tbs = _suite_tbs(ws, suite, tbs)
    held = [_acquire(ws, tb, jid, wait_s=60) for tb in locked_tbs]  # 회귀 동안 TB 잠금 (주인 = 작업 id)
    logf = ws / "out" / "regress" / f"{jid}.console.txt"
    logf.parent.mkdir(parents=True, exist_ok=True)
    with open(logf, "w", encoding="utf-8") as fh:
        proc = _spawn_detached(cmd, ws, fh)                 # 서버가 끝나도 회귀는 계속 (작업 상태는 파일로 확인)
    for p in held:                                          # 잠금의 pid를 회귀 프로세스로 (서버가 죽어도 유지)
        p.write_text(json.dumps({"pid": proc.pid, "owner": jid, "since": time.time()}), encoding="utf-8")
    _procs[jid] = proc
    job = {"id": jid, "kind": "regression", "workspace": str(ws), "pid": proc.pid, "tbs": locked_tbs,
           "console": str(logf), "summary": str(ws / "out" / "regress" / jid / "summary.json"),
           "command": " ".join(cmd[1:]), "started": time.time(), "state": "running"}
    _job_save(job)
    return {"id": jid, "console": str(logf), "command": job["command"], "locked_tbs": locked_tbs}


@server.tool()
def regression_status(id: str) -> dict:
    """start_regression으로 시작한 회귀의 상태: 실행 중이면 진행률, 끝났으면 집계와 실패한 실행 목록
    (재실행 명령 포함). 서버를 다시 띄운 뒤에도 확인할 수 있습니다."""
    job = _job_load(id)
    proc = _procs.get(id)
    running = (proc.poll() is None) if proc else (job["state"] == "running" and pid_alive(job["pid"]))
    console, summary = Path(job["console"]), Path(job["summary"])
    progress = ""
    if console.exists():
        prog = [l for l in console.read_text(encoding="utf-8", errors="replace").splitlines() if l.startswith("[")]
        progress = prog[-1] if prog else ""
    if running:
        return {"id": id, "state": "running", "progress": progress, "elapsed_s": round(time.time() - job["started"])}
    if job["state"] == "running":                           # 방금 끝남: 상태 기록, 잠금 해제
        job["state"] = "done" if summary.exists() else "interrupted"
        job["ended"] = time.time()
        _job_save(job)
        _job_finish_locks(job)
    if not summary.exists():
        return {"id": id, "state": job["state"], "progress": progress,
                "reason": "the regression process ended without a summary; usually the MCP server that started it "
                          "exited (the client closes the server's process tree). Start it again.",
                "rerun": "python " + job["command"].replace(job["workspace"] + os.sep, ""),
                "tail": _tail(console.read_text(encoding="utf-8", errors="replace") if console.exists() else "", 15)}
    s = json.loads(summary.read_text(encoding="utf-8"))
    fails = [r for r in s["results"] if not r["ok"]]
    return {"id": id, "state": job["state"], "runs": s["runs"], "fail": s["fail"], "xfail": s["xfail"],
            "build_fail": s["build_fail"], "elapsed_s": s.get("elapsed_s"),
            "failures": [{k: r.get(k) for k in ("tb", "test", "seed", "verdict", "reasons", "rerun")} for r in fails[:20]],
            "junit": str(summary.parent / "junit.xml"), "summary": str(summary)}


@server.tool()
def cancel_job(id: str) -> dict:
    """백그라운드 회귀를 멈춥니다 (시뮬레이터까지 프로세스 트리 전체 종료). 잠금도 풉니다."""
    job = _job_load(id)
    if job["state"] != "running":
        return {"id": id, "state": job["state"], "note": "not running"}
    kill_pid_tree(job["pid"])
    job.update(state="cancelled", ended=time.time())
    _job_save(job)
    _job_finish_locks(job)
    return {"id": id, "state": "cancelled"}


# --------------------------------------------------------------------------- 도구: 판정
@server.tool()
def coverage_report(tb: str, regress: list[str] | None = None, max_uncovered: int = 100, workspace: str = "") -> dict:
    """기능 커버리지를 합쳐 covergroup별 점수, 못 친 bin 목록, HTML 보고서 경로를 돌려줍니다.
    regress: 이 회귀(out/regress/<이름>)의 실행만 합침 (비우면 그 TB의 모든 실행)."""
    ws = _ws(workspace)
    _check_tb(ws, tb)
    cmd = [PY, _script(ws, "sim.py"), "cov-report", "--tb", tb]
    if regress:
        cmd += ["--regress", *[_name(n, "regression name") for n in regress]]
    with _locked(ws, [tb], f"coverage_report {tb}"):
        r = _run(ws, cmd, 900)
    rep = ws / "out" / tb / "cov"
    groups, unc = {}, []
    txt = rep / "func" / "xcrg_func_cov_report.txt"
    if txt.exists():
        body = txt.read_text(encoding="utf-8", errors="replace")
        rows = body.splitlines()
        hdr = next((i for i, l in enumerate(rows) if l.strip().startswith("CgName,")), None)
        if hdr is not None:                                 # 첫 "CgName," 표 = covergroup 요약
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
        unc = xcrg_report.uncovered(body)
    return {"ok": r.returncode == 0, "covergroups": groups, "uncovered_bins": unc[:max(0, max_uncovered)],
            "uncovered_total": len(unc), "func_html": str(rep / "func" / "dashboard.html"),
            "code_html": str(rep / "code" / "dashboard.html") if (rep / "code").exists() else None,
            "tail": _tail(r.stdout, 5)}


@server.tool()
def check_inventory(workspace: str = "") -> dict:
    """검사 목록을 기준선(verif/check_baseline.json)과 비교합니다. 사라지거나 줄어든 검사, 늘어난 억제 구문을
    돌려줍니다 (CLAUDE.md 규칙 5)."""
    ws = _ws(workspace)
    r = _run(ws, [PY, _script(ws, "check_inventory.py"), "--compare", "--json"], 120)
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"ok": False, "tail": _tail(r.stdout + r.stderr)}


@server.tool()
def run_gate(stage: str, workspace: str = "") -> dict:
    """단계의 완료 기준을 scripts/gate.py로 판정합니다 (예: static, A, B). 시뮬레이션은 돌리지 않고,
    정적 검사와 이미 있는 결과를 봅니다. 검사마다 PASS/FAIL, 내용, 재실행 명령을 돌려줍니다."""
    ws = _ws(workspace)
    stage = _name(stage, "stage")
    r = _run(ws, [PY, _script(ws, "gate.py"), stage], 3600)
    res = ws / "out" / "gate" / f"{stage}.json"
    if not res.exists():
        return {"ok": False, "tail": _tail(r.stdout + r.stderr)}
    doc = json.loads(res.read_text(encoding="utf-8"))
    return {"stage": stage, "verdict": doc["verdict"], "checks": doc["checks"], "result": str(res)}


@server.tool()
def signoff(level: str = "smoke", workspace: str = "") -> dict:
    """verif/SIGNOFF.md의 sign-off 기준을 지금 out/의 결과로 판정합니다 (level: smoke | nightly | release)."""
    ws = _ws(workspace)
    if level not in ("smoke", "nightly", "release"):
        raise ToolError("level must be smoke, nightly or release")
    _run(ws, [PY, _script(ws, "signoff.py"), "--level", level], 600)
    p = ws / "out" / "signoff" / "signoff.json"
    if not p.exists():
        raise ToolError("signoff.py produced no result")
    d = json.loads(p.read_text(encoding="utf-8"))
    return {"level": d["level"], "verdict": d["verdict"],
            "criteria": [{k: c[k] for k in ("id", "status", "detail")} for c in d["criteria"]],
            "result": str(p.with_suffix(".md"))}


@server.tool()
def compare_regressions(a: str, b: str, workspace_a: str = "", workspace_b: str = "") -> dict:
    """두 회귀(out/regress/<이름>/summary.json)의 판정을 (tb, test, seed)마다 비교합니다. 폴더 이동처럼 코드가
    바뀌지 않아야 하는 작업 뒤에 결과가 같은지 확인할 때 씁니다. 두 회귀 모두에 있는 실행만 비교합니다."""
    def load(ws: Path, name: str) -> dict:
        p = ws / "out" / "regress" / _name(name, "regression name") / "summary.json"
        if not p.exists():
            raise ToolError(f"no regression summary {p}")
        return {(r["tb"], r["test"], r["seed"]): r["verdict"] for r in json.loads(p.read_text(encoding="utf-8"))["results"]}
    ra, rb = load(_ws(workspace_a), a), load(_ws(workspace_b), b)
    both = sorted(set(ra) & set(rb))
    diff = [{"tb": k[0], "test": k[1], "seed": k[2], "a": ra[k], "b": rb[k]} for k in both if ra[k] != rb[k]]
    return {"same": not diff and bool(both), "compared": len(both), "differences": diff[:50],
            "only_in_a": len(set(ra) - set(rb)), "only_in_b": len(set(rb) - set(ra))}


# --------------------------------------------------------------------------- 도구: ledger
def _ledger(loop_id: str) -> Path:
    return ROOT / "out" / "loop" / _name(loop_id, "loop id") / "ledger.json"


@server.tool()
def ledger_append(loop_id: str, kind: str, summary: str, data: dict | None = None, workspace: str = "") -> dict:
    """작업 기록(out/loop/<loop_id>/ledger.json)에 항목을 덧붙입니다. 결과마다 재실행 명령과 결과 파일 경로를
    data에 넣으면, 다른 세션이 ledger_read로 이어 갈 수 있습니다."""
    p = _ledger(loop_id)
    p.parent.mkdir(parents=True, exist_ok=True)
    led = json.loads(p.read_text(encoding="utf-8")) if p.exists() else {"entries": []}
    entry = {"kind": _name(kind, "kind"), "time": time.strftime("%Y-%m-%d %H:%M:%S"), "summary": summary[:2000],
             "workspace": str(_ws(workspace)), "data": data or {}}
    led["entries"].append(entry)
    p.write_text(json.dumps(led, indent=2, ensure_ascii=False), encoding="utf-8")
    return {"ledger": str(p), "entries": len(led["entries"])}


@server.tool()
def ledger_read(loop_id: str, last: int = 20) -> dict:
    """작업 기록의 마지막 항목들을 돌려줍니다 (gate.py --ledger와 ledger_append가 쓴 것)."""
    p = _ledger(loop_id)
    if not p.exists():
        return {"ledger": str(p), "entries": []}
    ent = json.loads(p.read_text(encoding="utf-8"))["entries"]
    return {"ledger": str(p), "total": len(ent), "entries": ent[-max(1, min(last, 200)):]}


if __name__ == "__main__":
    server.run("stdio")
