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
from __future__ import annotations                          # 타입 힌트를 문자열로 지연 평가

import json                                                 # sim_cfg.json, result.json, summary.json 처리
import re                                                   # 인자 검증과 로그 필터 정규식
import subprocess                                           # sim.py / regress.py 실행
import sys                                                  # 현재 Python 경로
import time                                                 # 시각 문자열, 경과 시간
import uuid                                                 # 회귀 id의 랜덤 꼬리
from pathlib import Path                                    # 경로 처리
from typing import Any                                      # 타입 힌트용

from mcp.server.mcpserver import MCPServer                  # MCP 서버 클래스
from mcp.server.mcpserver.exceptions import ToolError  # 메시지가 에이전트에게 전달됨

ROOT = Path(__file__).resolve().parents[2]                  # 저장소 루트 (mcp/vivado_mcp/의 두 단계 위)
OUT = ROOT / "out"                                          # 결과 출력 디렉터리
CFG_PATH = ROOT / "verif" / "sim_cfg.json"                  # 테스트벤치 설정 파일
SIM = ROOT / "scripts" / "sim.py"                           # sim.py 경로
REGRESS = ROOT / "scripts" / "regress.py"                   # regress.py 경로
# 시뮬레이션 스크립트는 이 venv가 아니라 시스템 Python으로 실행 (Jenkins와 같음).
PY = sys.executable                                         # 기본값: 이 서버를 실행한 Python
_sys_py = Path.home() / "AppData/Local/Programs/Python/Python313/python.exe"  # 시스템 Python 3.13 경로
if _sys_py.exists():                                        # 있으면
    PY = str(_sys_py)                                       # 그것을 사용

ARG_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(=[A-Za-z0-9_.:+-]*)?$")  # plusarg/define 허용 패턴: NAME 또는 NAME=value
SEED_RE = re.compile(r"^(random|\d{1,10})$")                # seed 허용 패턴: random 또는 10자리 이하 정수
MAX_SYNC_S = 900                 # 동기 도구 호출의 최대 시간
_regressions: dict[str, dict[str, Any]] = {}                # 회귀 id -> 실행 중인 프로세스 정보

server = MCPServer(                                         # MCP 서버 생성
    name="vivado-mcp",                                      # 서버 이름
    version="1.0.0",                                        # 서버 버전
    instructions=(                                          # 에이전트에게 주는 사용 안내
        "Vivado 2022.2 XSim UVM flow for dma_ip. Start with list_testbenches. "  # 흐름 소개와 첫 도구
        "Use run_test for one test/seed and get_log_excerpt to debug a failure. "  # 테스트 하나 실행과 디버그 방법
        "Use start_regression + regression_status for many runs. "  # 여러 실행은 회귀 도구로
        "Never modify RTL under HW/: report RTL bugs instead (see list_known_bugs)."  # RTL은 고치지 말라는 규칙
    ),                                                      # 안내 끝
)                                                           # MCPServer 생성 끝


# --------------------------------------------------------------------------- helpers
def _cfg() -> dict:                                         # sim_cfg.json을 읽는 함수
    return json.loads(CFG_PATH.read_text(encoding="utf-8"))  # JSON 파싱 결과 반환


def _check_tb(tb: str) -> dict:                             # TB 이름을 검증하고 설정을 돌려주는 함수
    tbs = _cfg()["tbs"]                                     # TB 목록
    if tb not in tbs:                                       # 등록되지 않은 TB면
        raise ToolError(f"unknown tb '{tb}'. Known: {', '.join(tbs)}")  # 에이전트에게 오류와 알려진 TB 목록 전달
    return tbs[tb]                                          # TB 설정 반환


def _check_test(tbcfg: dict, test: str | None) -> str:      # 테스트 이름을 검증하는 함수 (없으면 기본 테스트)
    tests = tbcfg.get("tests") or [tbcfg.get("default_test")]  # 등록된 테스트 목록
    test = test or tbcfg.get("default_test")                # 지정이 없으면 기본 테스트
    if test not in tests:                                   # 목록에 없으면
        raise ToolError(f"unknown test '{test}' for this tb. Known: {', '.join(t for t in tests if t)}")  # 오류와 알려진 테스트 목록 전달
    return test                                             # 테스트 이름 반환


def _check_args(values: list[str] | None, what: str) -> list[str]:  # plusarg/define 목록을 검증하는 함수
    for v in values or []:                                  # 값마다
        if not ARG_RE.match(v):                             # 허용 패턴에 맞지 않으면
            raise ToolError(f"invalid {what} '{v}' (allowed: NAME or NAME=value, [A-Za-z0-9_.:+-])")  # 오류 전달
    return list(values or [])                               # 복사본 반환


def _run(cmd: list[str], timeout: int) -> subprocess.CompletedProcess:  # 저장소 루트에서 명령을 실행하는 함수
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True,  # 출력을 문자열로 받음
                          encoding="utf-8", errors="replace", timeout=timeout)  # UTF-8로 읽고 시간 제한 적용


def _tail(text: str, n: int = 15) -> str:                   # 텍스트의 마지막 n줄을 돌려주는 함수
    return "\n".join(text.strip().splitlines()[-n:])        # 마지막 n줄만 이어 붙임


def _safe_out_path(p: Path) -> Path:                        # 경로가 out/ 안인지 확인하는 함수
    p = p.resolve()                                         # 절대 경로로 정리 (.. 제거)
    if OUT.resolve() not in p.parents:                      # out/ 아래가 아니면
        raise ToolError("path outside out/ is not accessible")  # 접근 거부
    return p                                                # 경로 반환


# --------------------------------------------------------------------------- tools
@server.tool()                                              # MCP 도구로 등록
def list_testbenches() -> dict:                             # list_testbenches 도구
    """등록된 테스트벤치와 각각의 테스트, 기본 테스트, known-fail(RTL 버그) 항목을 보여 줍니다."""  # 도구 설명 (에이전트에게 보임)
    out = {}                                                # 결과 사전
    for name, t in _cfg()["tbs"].items():                   # TB마다
        out[name] = {"desc": t.get("desc", ""), "uvm": t.get("uvm", False),  # 설명, UVM 여부
                     "tests": t.get("tests") or ([t["default_test"]] if t.get("default_test") else []),  # 테스트 목록 (없으면 기본 테스트 하나)
                     "default_test": t.get("default_test"),  # 기본 테스트
                     "known_fail": t.get("known_fail", {}),  # known_fail 항목
                     "expect": t.get("expect", "pass")}     # 기대 결과 (pass / fail)
    return out                                              # 결과 반환


@server.tool()                                              # MCP 도구로 등록
def lint(tb: str, defines: list[str] | None = None) -> dict:  # lint 도구
    """테스트벤치를 시뮬레이션 없이 컴파일하고 elaborate합니다 (xvlog + xelab).
    ok와, 실패했다면 처음 나온 컴파일 에러를 돌려줍니다."""
    _check_tb(tb)                                           # TB 이름 검증
    cmd = [PY, str(SIM), "lint", "--tb", tb]                # sim.py lint 명령
    for d in _check_args(defines, "define"):                # 검증한 define마다
        cmd += ["--define", d]                              # 인자 추가
    r = _run(cmd, 600)                                      # 실행 (최대 10분)
    errs = [l for l in (r.stdout + r.stderr).splitlines() if re.match(r"^\s*(ERROR|FATAL_ERROR):", l)]  # 출력에서 도구 오류 줄 모음
    return {"ok": r.returncode == 0, "errors": errs[:20],   # 성공 여부와 오류 최대 20개
            "logs": [str(OUT / tb / "build" / f) for f in ("xvlog.log", "xelab.log")],  # 빌드 로그 경로
            "tail": "" if r.returncode == 0 else _tail(r.stdout)}  # 실패했으면 출력 마지막 15줄


@server.tool()                                              # MCP 도구로 등록
def run_test(tb: str, test: str | None = None, seed: str = "1", plusargs: list[str] | None = None,  # run_test 도구
             rebuild: bool = True, coverage: bool = False, wave: bool = False,  # 빌드 여부, 커버리지, 파형
             timeout_s: int = 600) -> dict:                 # 시간 제한 (초)
    """UVM 테스트 하나를 seed 하나로 실행합니다 (seed: 정수 또는 'random').
    판정(PASS/FAIL/XFAIL/XPASS), 실패 이유, 처음 나온 UVM 에러, 로그 경로, 이 실행을
    그대로 재현하는 명령을 돌려줍니다.
    rebuild=False면 이 tb의 마지막 빌드를 다시 씀 (더 빠름, 소스가 같을 때)."""
    tbcfg = _check_tb(tb)                                   # TB 이름 검증
    test = _check_test(tbcfg, test)                         # 테스트 이름 검증
    if not SEED_RE.match(seed):                             # seed 형식이 틀리면
        raise ToolError("seed must be an integer or 'random'")  # 오류 전달
    timeout_s = max(30, min(int(timeout_s), MAX_SYNC_S))    # 시간 제한을 30초..최대값으로 자름
    cmd = [PY, str(SIM), "run", "--tb", tb, "--test", test, "--seed", seed, "--timeout", str(timeout_s)]  # sim.py run 명령
    for p in _check_args(plusargs, "plusarg"):              # 검증한 plusarg마다
        cmd += ["--plusarg", p]                             # 인자 추가
    if not rebuild:                                         # 다시 빌드하지 않으면
        cmd.append("--no-build")                            # --no-build 추가
    if coverage:                                            # 커버리지를 원하면
        cmd.append("--cov")                                 # --cov 추가
    if wave:                                                # 파형을 원하면
        cmd.append("--wave")                                # --wave 추가
    r = _run(cmd, timeout_s + 600)                          # 실행 (빌드 시간 여유 10분 추가)
    if r.returncode == 2:                                   # 종료 코드 2면 빌드 실패
        return {"verdict": "BUILD_FAIL", "ok": False, "tail": _tail(r.stdout, 25)}  # 빌드 실패와 출력 마지막 25줄
    m = re.search(r"^\[\S+\] tb=\S+ test=\S+ seed=(\d+)", r.stdout, re.M)   # sim.py 판정 줄
    real_seed = m.group(1) if m else seed                   # 실제 seed (random이면 출력에서 찾은 값)
    rj = OUT / tb / "runs" / f"{test}_{real_seed}" / "result.json"  # 결과 파일 경로
    if not rj.exists():                                     # 결과 파일이 없으면
        return {"verdict": "NO_RESULT", "ok": False, "tail": _tail(r.stdout, 25)}  # NO_RESULT와 출력 마지막 25줄
    res = json.loads(rj.read_text(encoding="utf-8"))        # 결과 읽기
    keep = ("tb", "test", "seed", "verdict", "ok", "reasons", "first_errors", "uvm_counts",  # 에이전트에게 돌려줄 필드
            "known_fail", "duration_s", "sim_end_time", "log", "rerun")  # (필드 목록 계속)
    res = {k: res[k] for k in keep if k in res}             # 그 필드만 남김
    res["first_errors"] = [e[:300] for e in res.get("first_errors", [])[:5]]  # 첫 오류는 5개, 각 300자까지
    if wave:                                                # 파형을 기록했으면
        res["wave"] = str(rj.parent / "wave.wdb")           # 파형 파일 경로 추가
    return res                                              # 결과 반환


@server.tool()                                              # MCP 도구로 등록
def get_log_excerpt(tb: str, test: str, seed: str, pattern: str | None = None,  # get_log_excerpt 도구
                    context: int = 2, max_lines: int = 80) -> dict:  # 앞뒤 줄 수, 최대 줄 수
    """run.log에서 걸러낸 일부를 돌려줍니다 (파일 전체는 절대 돌려주지 않음).
    기본 필터: UVM_ERROR/UVM_FATAL/SVA/scoreboard/JOB/TEST 줄과 report 요약.
    pattern: 다른 줄을 고를 정규식, 선택 사항 (예: 'AXI_AW|AXI_W')."""
    _check_tb(tb)                                           # TB 이름 검증
    if not SEED_RE.match(seed) or seed == "random":         # seed가 정수가 아니면
        raise ToolError("seed must be the integer seed of an existing run")  # 오류 전달
    log = _safe_out_path(OUT / tb / "runs" / f"{test}_{seed}" / "run.log")  # 로그 경로 (out/ 안인지 확인)
    if not log.exists():                                    # 로그가 없으면
        raise ToolError(f"no log for {tb}/{test}/{seed}. Run it first.")  # 먼저 실행하라는 오류
    rx = re.compile(pattern) if pattern else re.compile(    # pattern이 있으면 그것, 없으면 기본 필터
        r"^(UVM_ERROR|UVM_FATAL)\s+(?!:)|\[(SB_[A-Z_]+|JOB|TEST|COV|AXI_[A-Z0-9_]+|VR_SVA|AXIL_SVA|AXI_SVA)\]"  # UVM 오류 메시지와 주요 태그 줄
        r"|^UVM_(ERROR|FATAL|WARNING)\s*:\s*\d+|^ERROR:|FATAL_ERROR")  # UVM 요약 개수 줄과 도구 오류 줄
    lines = log.read_text(encoding="utf-8", errors="replace").splitlines()  # 로그 줄 목록
    keep: set[int] = set()                                  # 남길 줄 번호
    for i, l in enumerate(lines):                           # 줄마다
        if rx.search(l):                                    # 필터에 맞으면
            keep.update(range(max(0, i - context), min(len(lines), i + context + 1)))  # 앞뒤 context줄까지 포함
    sel = sorted(keep)                                      # 줄 번호 정렬
    excerpt, prev = [], -2                                  # 결과 줄, 직전 줄 번호
    for i in sel[: max(1, min(max_lines, 400))]:            # 최대 줄 수(1..400)까지
        if i != prev + 1:                                   # 연속되지 않으면
            excerpt.append(f"... (line {i + 1})")           # 건너뛴 위치 표시
        excerpt.append(lines[i][:400])                      # 줄 추가 (400자까지)
        prev = i                                            # 직전 줄 번호 갱신
    return {"log": str(log), "total_lines": len(lines), "matched_lines": len(sel),  # 로그 경로, 전체 줄 수, 맞은 줄 수
            "truncated": len(sel) > max_lines, "excerpt": "\n".join(excerpt)}  # 잘렸는지, 발췌 내용


@server.tool()                                              # MCP 도구로 등록
def start_regression(suite: str | None = "unit", tbs: list[str] | None = None,  # start_regression 도구
                     tests: list[str] | None = None, seeds: int = 1, jobs: int = 6) -> dict:  # 테스트 목록, seed 수, 병렬 수
    """회귀를 백그라운드에서 시작합니다 (suite: unit|top|all, 또는 tbs를 직접 지정).
    회귀 id를 돌려줍니다. regression_status로 진행 상황을 확인합니다."""
    cfg_tbs = _cfg()["tbs"]                                 # TB 설정
    for t in tbs or []:                                     # 지정한 TB마다
        _check_tb(t)                                        # 검증
    known_tests = {x for v in cfg_tbs.values() for x in (v.get("tests") or [])}  # 모든 TB의 테스트 이름 집합
    for t in tests or []:                                   # 지정한 테스트마다
        if t not in known_tests:                            # 모르는 테스트면
            raise ToolError(f"unknown test '{t}'")          # 오류 전달
    if suite not in (None, "unit", "top", "all"):           # suite 값이 틀리면
        raise ToolError("suite must be unit, top or all")   # 오류 전달
    if not (tbs or suite):                                  # suite도 TB도 없으면
        raise ToolError("give a suite or tbs")              # 오류 전달
    rid = time.strftime("mcp_%Y%m%d_%H%M%S_") + uuid.uuid4().hex[:4]  # 회귀 id: 시각 + 랜덤 4자리
    cmd = [PY, str(REGRESS), "--seeds", str(max(1, min(seeds, 50))),  # regress.py 명령 (seed 수는 1..50)
           "--jobs", str(max(1, min(jobs, 8))), "--name", rid]  # 병렬 수는 1..8, 보고서 이름 = id
    if tbs:                                                 # TB를 지정했으면
        cmd += ["--tb", *tbs]                               # 인자 추가
    if suite:                                               # suite를 지정했으면
        cmd += ["--suite", suite]                           # 인자 추가
    if tests:                                               # 테스트를 지정했으면
        cmd += ["--tests", *tests]                          # 인자 추가
    logf = OUT / "regress" / f"{rid}.console.txt"           # 콘솔 출력 파일
    logf.parent.mkdir(parents=True, exist_ok=True)          # 디렉터리 생성
    fh = open(logf, "w", encoding="utf-8")                  # 파일 열기
    proc = subprocess.Popen(cmd, cwd=ROOT, stdout=fh, stderr=subprocess.STDOUT)  # 백그라운드로 실행
    _regressions[rid] = {"proc": proc, "console": logf, "fh": fh, "started": time.time()}  # 프로세스 정보 저장
    return {"id": rid, "console": str(logf), "command": " ".join(cmd[1:])}  # id, 콘솔 파일, 명령 반환


@server.tool()                                              # MCP 도구로 등록
def regression_status(id: str) -> dict:                     # regression_status 도구
    """start_regression으로 시작한 회귀의 상태: 실행 중이면 진행률,
    끝났으면 집계와 실패한 실행 목록(재실행 명령 포함)."""
    if not re.match(r"^mcp_\d{8}_\d{6}_[0-9a-f]{4}$", id):  # id 형식이 틀리면
        raise ToolError("invalid regression id")            # 오류 전달
    info = _regressions.get(id)                             # 이 서버가 시작한 회귀 정보
    console = OUT / "regress" / f"{id}.console.txt"         # 콘솔 출력 파일
    summary = OUT / "regress" / id / "summary.json"         # 요약 파일
    running = bool(info and info["proc"].poll() is None)    # 아직 실행 중인지
    if info and not running and not info["fh"].closed:      # 끝났는데 파일이 열려 있으면
        info["fh"].close()                                  # 닫음
    progress = ""                                           # 진행 상황 줄
    if console.exists():                                    # 콘솔 파일이 있으면
        prog = [l for l in console.read_text(encoding="utf-8", errors="replace").splitlines()  # [로 시작하는 진행 줄만
                if l.startswith("[")]                       # (조건 계속)
        progress = prog[-1] if prog else ""                 # 마지막 진행 줄
    if running or not summary.exists():                     # 실행 중이거나 요약이 없으면
        return {"id": id, "state": "running" if running else "unknown", "progress": progress,  # 상태와 진행 상황
                "elapsed_s": round(time.time() - info["started"]) if info else None}  # 경과 시간
    s = json.loads(summary.read_text(encoding="utf-8"))     # 요약 읽기
    fails = [r for r in s["results"] if not r["ok"]]        # 실패한 실행
    return {"id": id, "state": "done", "runs": s["runs"], "fail": s["fail"], "xfail": s["xfail"],  # 완료 상태와 집계
            "build_fail": s["build_fail"], "elapsed_s": s.get("elapsed_s"),  # 빌드 실패, 걸린 시간
            "failures": [{k: r[k] for k in ("tb", "test", "seed", "verdict", "reasons", "rerun")}  # 실패 목록 (필드 일부)
                         for r in fails[:20]],              # 최대 20개
            "junit": str(summary.parent / "junit.xml")}     # JUnit 파일 경로


@server.tool()                                              # MCP 도구로 등록
def coverage_report(tb: str) -> dict:                       # coverage_report 도구
    """tb의 모든 실행에서 기능 커버리지를 합치고 (coverage=True로 빌드했다면 코드 커버리지도),
    covergroup별 점수와 HTML 보고서 경로를 돌려줍니다."""
    _check_tb(tb)                                           # TB 이름 검증
    r = _run([PY, str(SIM), "cov-report", "--tb", tb], 600)  # sim.py cov-report 실행
    rep = OUT / tb / "cov"                                  # 보고서 디렉터리
    groups = {}                                             # covergroup -> 점수
    txt = rep / "func" / "xcrg_func_cov_report.txt"         # 기능 커버리지 텍스트 보고서
    if txt.exists():                                        # 있으면
        # 첫 "CgName," 표 = 모든 covergroup 요약: "<name> ,<score> ,..."
        rows = txt.read_text(encoding="utf-8", errors="replace").splitlines()  # 줄 목록
        hdr = next((i for i, l in enumerate(rows) if l.strip().startswith("CgName,")), None)  # CgName, 헤더 줄 위치
        if hdr is not None:                                 # 찾았으면
            for l in rows[hdr + 1:]:                        # 헤더 다음 줄부터
                if not l.strip():                           # 빈 줄이면
                    if groups:                              # 이미 읽은 행이 있으면
                        break                               # 표 끝
                    continue                                # 아니면 계속
                cells = [c.strip() for c in l.split(",")]   # 쉼표로 나눔
                try:                                        # 점수 변환
                    groups[cells[0]] = float(cells[1])      # 이름 -> 점수
                except (IndexError, ValueError):            # 형식이 다르면
                    break                                   # 표 끝
    return {"ok": r.returncode == 0, "covergroups": groups,  # 성공 여부와 covergroup 점수
            "func_html": str(rep / "func" / "dashboard.html"),  # 기능 커버리지 HTML
            "code_html": str(rep / "code" / "dashboard.html") if (rep / "code").exists() else None,  # 코드 커버리지 HTML (있을 때만)
            "tail": _tail(r.stdout, 5)}                     # 출력 마지막 5줄


@server.tool()                                              # MCP 도구로 등록
def list_known_bugs() -> dict:                              # list_known_bugs 도구
    """검증에서 찾은 RTL 버그(verif/BUGS.md)와, 그 버그를 known_fail로 추적하는 테스트.
    RTL은 읽기 전용이라 보고만 하고, 이 흐름에서 고치지 않습니다."""
    bugs = {}                                               # 버그 id -> 정보
    md = (ROOT / "verif" / "BUGS.md").read_text(encoding="utf-8")  # BUGS.md 읽기
    for m in re.finditer(r"^## (BUG-\d+): (.+?)$(.*?)(?=^## |\Z)", md, re.M | re.S):  # ## BUG-NNN: 제목 절마다
        status = re.search(r"\*\*(?:상태|Status):\*\*\s*(.+)", m.group(3))  # 상태 줄
        repro = re.search(r"\*\*(?:재현|Reproducer):\*\*\s*`([^`]+)`", m.group(3))  # 재현 명령 줄
        bugs[m.group(1)] = {"title": m.group(2).strip(),    # 제목
                            "status": status.group(1).strip() if status else "",  # 상태
                            "reproducer": repro.group(1) if repro else ""}  # 재현 명령
    tracked = {}                                            # 버그 id -> 추적 테스트 목록
    for tb, t in _cfg()["tbs"].items():                     # TB마다
        for test, why in t.get("known_fail", {}).items():   # known_fail 항목마다
            bid = (re.match(r"(BUG-\d+)", why) or [None, "?"])[1]  # 사유 앞의 BUG-NNN 추출 (없으면 ?)
            tracked.setdefault(bid, []).append(f"{tb}/{test}")  # 추적 목록에 추가
    for bid, b in bugs.items():                             # 버그마다
        b["tracked_by"] = tracked.get(bid, [])              # 추적 테스트 연결
    return bugs                                             # 결과 반환


if __name__ == "__main__":                                  # 스크립트로 실행될 때만
    server.run("stdio")                                     # stdio로 MCP 서버 실행
