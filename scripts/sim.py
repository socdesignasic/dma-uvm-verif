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
from __future__ import annotations                          # 타입 힌트를 문자열로 지연 평가 (list[str] 등)

import argparse                                             # 명령줄 인자 파싱
import json                                                 # sim_cfg.json, result.json 읽기/쓰기
import os                                                   # 환경 변수, OS 종류 확인
import random                                               # 랜덤 seed 생성
import re                                                   # 정규식 (로그 파싱)
import shutil                                               # 디렉터리 복사/삭제, 실행 파일 찾기
import subprocess                                           # Vivado 도구 실행
import sys                                                  # 종료 코드와 표준 출력
import time                                                 # 실행 시간 측정, 시각 문자열
from pathlib import Path                                    # 경로 처리
from xml.sax.saxutils import escape                         # JUnit XML 특수문자 이스케이프

# 한글 출력이 Jenkins/MCP(UTF-8로 읽음)에서 깨지지 않도록 출력 인코딩을 UTF-8로 고정
for _s in (sys.stdout, sys.stderr):                         # 표준 출력과 표준 오류 각각
    if hasattr(_s, "reconfigure"):                          # reconfigure를 지원하면 (Python 3.7+)
        _s.reconfigure(encoding="utf-8", errors="replace")  # UTF-8로 바꾸고, 못 바꾸는 문자는 ?로

ROOT = Path(__file__).resolve().parent.parent               # 저장소 루트 (scripts/의 상위)
CFG_PATH = ROOT / "verif" / "sim_cfg.json"                  # 테스트벤치 설정 파일 경로
OUT = ROOT / "out"                                          # 결과 출력 디렉터리


# --------------------------------------------------------------------------- #
# 도구 찾기
# --------------------------------------------------------------------------- #
def vivado_bin(cfg: dict) -> Path:                          # Vivado bin 디렉터리를 찾는 함수
    """XILINX_VIVADO 환경 변수 -> PATH -> 기본 설치 위치 순으로 찾음."""   # 함수 설명
    env = os.environ.get("XILINX_VIVADO")                   # XILINX_VIVADO 환경 변수 읽기
    if env and (Path(env) / "bin").is_dir():                # 설정돼 있고 bin 폴더가 있으면
        return Path(env) / "bin"                            # 그 bin 사용
    found = shutil.which("xvlog")                           # PATH에서 xvlog 찾기
    if found:                                               # 찾았으면
        return Path(found).parent                           # 그 폴더 사용
    default = Path(f"C:/Xilinx/Vivado/{cfg.get('vivado_version', '2022.2')}/bin")  # 기본 설치 위치 (버전은 sim_cfg.json에서)
    if default.is_dir():                                    # 있으면
        return default                                      # 그 폴더 사용
    sys.exit("ERROR: Vivado not found. Set XILINX_VIVADO or add Vivado/bin to PATH.")  # 못 찾으면 오류로 종료


def tool(cfg: dict, name: str) -> str:                      # 도구 실행 파일 경로를 돌려주는 함수
    b = vivado_bin(cfg)                                     # Vivado bin 디렉터리
    exe = b / (name + ".bat") if os.name == "nt" else b / name  # Windows면 .bat wrapper, 아니면 실행 파일 그대로
    return str(exe)                                         # 문자열로 반환


# --------------------------------------------------------------------------- #
# filelist(.f) 파싱: 파일, +incdir+, +define+, 중첩 -f, // 또는 # 주석
# --------------------------------------------------------------------------- #
def parse_filelist(path: Path, acc=None) -> dict:           # filelist를 읽어 파일/incdir/define 목록에 더하는 함수
    acc = acc or {"files": [], "incdirs": [], "defines": []}  # 처음 호출이면 빈 목록 생성
    base = path.parent                                      # 상대 경로의 기준 디렉터리
    for raw in path.read_text(encoding="utf-8").splitlines():  # 파일의 각 줄마다
        line = raw.split("//", 1)[0].strip()                # // 뒤 주석을 잘라내고 공백 제거
        if not line or line.startswith("#"):                # 빈 줄이나 # 주석 줄이면
            continue                                        # 건너뜀
        if line.startswith("+incdir+"):                     # +incdir+ 줄이면
            for d in line[len("+incdir+"):].split("+"):     # +로 나뉜 디렉터리마다
                if d:                                       # 비어 있지 않으면
                    acc["incdirs"].append(str((base / d).resolve()))  # 절대 경로로 incdir 목록에 추가
        elif line.startswith("+define+"):                   # +define+ 줄이면
            acc["defines"] += [d for d in line[len("+define+"):].split("+") if d]  # +로 나뉜 define을 목록에 추가
        elif line.startswith("-f "):                        # -f 줄이면 (다른 filelist 포함)
            parse_filelist((base / line[3:].strip()).resolve(), acc)  # 그 filelist를 재귀로 읽음
        else:                                               # 그 밖에는 소스 파일
            p = (base / line).resolve()                     # 절대 경로로 변환
            if not p.exists():                              # 파일이 없으면
                sys.exit(f"ERROR: {path.name}: file not found: {p}")  # 오류로 종료
            acc["files"].append(str(p))                     # 소스 파일 목록에 추가
    return acc                                              # 결과 반환


# --------------------------------------------------------------------------- #
# 보조 함수
# --------------------------------------------------------------------------- #
def load_cfg() -> dict:                                     # sim_cfg.json을 읽는 함수
    return json.loads(CFG_PATH.read_text(encoding="utf-8"))  # JSON 파싱 결과 반환


def get_tb(cfg: dict, name: str) -> dict:                   # 이름으로 TB 설정을 찾는 함수
    if name not in cfg["tbs"]:                              # 등록되지 않은 TB면
        sys.exit(f"ERROR: unknown tb '{name}'. Known: {', '.join(cfg['tbs'])}")  # 알려진 TB 목록과 함께 오류 종료
    return cfg["tbs"][name]                                 # TB 설정 반환


def win_cmdline(cmd: list[str]) -> str:                     # 명령 목록을 Windows 명령줄 문자열로 바꾸는 함수
    """Windows의 Vivado 도구는 .bat wrapper라서, cmd.exe가 따옴표 없는 인자를
    '=' ',' ';'에서 나눔 (예: UVM_TESTNAME=foo -> 'UVM_TESTNAME' 'foo'). 그래서 따옴표로 감쌈."""
    out = []                                                # 결과 인자 목록
    for c in cmd:                                           # 인자마다
        # 역슬래시 경로는 XSim이 만드는 C 문자열 안에 들어가 ("\U", "\D" ...)
        # 코드 커버리지 elaboration을 깨뜨림. 슬래시(/)는 어디서나 동작함.
        c = c.replace("\\", "/")                            # 역슬래시를 슬래시로
        out.append(f'"{c}"' if re.search(r'[\s=,;&()^]', c) and not c.startswith('"') else c)  # 공백이나 특수문자가 있으면 큰따옴표로 감쌈
    return " ".join(out)                                    # 공백으로 이어 붙여 반환


def run_tool(cmd: list[str], cwd: Path, timeout: int | None = None) -> int:  # 도구를 실행하고 종료 코드를 돌려주는 함수
    line = win_cmdline(cmd) if os.name == "nt" else cmd     # Windows면 명령줄 문자열, 아니면 목록 그대로
    print(">>", line if isinstance(line, str) else " ".join(line), flush=True)  # 실행할 명령을 출력
    try:                                                    # 시간 제한 처리
        p = subprocess.run(line, cwd=cwd, timeout=timeout)  # 도구 실행 (끝날 때까지 대기)
        return p.returncode                                 # 종료 코드 반환
    except subprocess.TimeoutExpired:                       # 시간 초과면
        print(f"ERROR: timeout after {timeout}s", flush=True)  # 오류 출력
        return 124                                          # timeout 관례 종료 코드 124


def count_errors(log: Path) -> list[str]:                   # 로그에서 도구 오류 줄을 모으는 함수
    if not log.exists():                                    # 로그가 없으면
        return [f"missing log {log}"]                       # 없다는 것 자체를 오류로
    txt = log.read_text(encoding="utf-8", errors="replace")  # 로그 읽기 (깨진 문자는 대체)
    return [l for l in txt.splitlines() if re.match(r"^\s*(ERROR|FATAL_ERROR):", l)]  # ERROR: / FATAL_ERROR: 로 시작하는 줄 목록


# --------------------------------------------------------------------------- #
# 빌드 (xvlog + xelab)
# --------------------------------------------------------------------------- #
def build(cfg: dict, tb_name: str, defines: list[str], cov: bool, wave: bool) -> Path:  # xvlog + xelab로 snapshot을 만드는 함수
    tb = get_tb(cfg, tb_name)                               # TB 설정
    bdir = OUT / tb_name / "build"                          # 빌드 디렉터리
    if bdir.exists():                                       # 이전 빌드가 있으면
        shutil.rmtree(bdir, ignore_errors=True)             # 지움
    bdir.mkdir(parents=True, exist_ok=True)                 # 빌드 디렉터리 생성

    fl = {"files": [], "incdirs": [], "defines": []}        # 파일/incdir/define 모을 곳
    for f in tb["filelists"]:                               # TB의 filelist마다
        parse_filelist(ROOT / f, fl)                        # 읽어서 모음
    all_defs = fl["defines"] + tb.get("defines", []) + defines  # filelist + sim_cfg + 명령줄 define 합침

    cmd = [tool(cfg, "xvlog"), "--sv", "--log", str(bdir / "xvlog.log")]  # xvlog 명령: SystemVerilog, 로그 파일
    if tb.get("uvm"):                                       # UVM TB면
        cmd += ["-L", "uvm"]                                # UVM 라이브러리 사용
    for d in fl["incdirs"]:                                 # incdir마다
        cmd += ["-i", d]                                    # -i 인자 추가
    for d in all_defs:                                      # define마다
        cmd += ["-d", d]                                    # -d 인자 추가
    cmd += fl["files"]                                      # 소스 파일 추가
    rc = run_tool(cmd, bdir)                                # xvlog 실행 (컴파일)
    errs = count_errors(bdir / "xvlog.log")                 # 로그에서 오류 줄 모음
    if rc != 0 or errs:                                     # 실패했으면
        print("\n".join(errs[:20]))                         # 오류 줄 최대 20개 출력
        print(f"BUILD FAILED (xvlog) - see {bdir / 'xvlog.log'}")  # 실패 메시지
        sys.exit(2)                                         # 종료 코드 2 (빌드 실패)

    snap = f"{tb_name}_snap"                                # snapshot 이름
    cmd = [tool(cfg, "xelab"), tb["top"], "-s", snap,       # xelab 명령: top 모듈, snapshot 이름
           "--timescale", "1ns/1ps", "--log", str(bdir / "xelab.log")]  # timescale, 로그 파일
    if tb.get("uvm"):                                       # UVM TB면
        cmd += ["-L", "uvm"]                                # UVM 라이브러리 사용
    cmd += ["--debug", "typical" if wave else "off"]        # 파형이 필요하면 debug typical, 아니면 off
    if cov:                                                 # 코드 커버리지를 켜면
        cmd += ["--cc_type", "sbct", "--cc_dir", str(bdir / "codecov"), "--cc_db", snap,  # statement/branch/condition/toggle 커버리지 DB 설정
                "--cov_db_dir", str(bdir / "funccov"), "--cov_db_name", snap]  # 기능 커버리지 DB 설정
    rc = run_tool(cmd, bdir)                                # xelab 실행 (elaboration)
    errs = count_errors(bdir / "xelab.log")                 # 로그에서 오류 줄 모음
    if rc != 0 or errs:                                     # 실패했으면
        print("\n".join(errs[:20]))                         # 오류 줄 최대 20개 출력
        print(f"BUILD FAILED (xelab) - see {bdir / 'xelab.log'}")  # 실패 메시지
        sys.exit(2)                                         # 종료 코드 2

    meta = {"tb": tb_name, "snapshot": snap, "defines": all_defs, "cov": cov, "wave": wave,  # 빌드 정보 기록용 사전
            "files": fl["files"], "time": time.strftime("%Y-%m-%d %H:%M:%S")}  # 파일 목록과 빌드 시각
    (bdir / "build.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")  # build.json으로 저장
    print(f"BUILD OK: {tb_name} -> {snap}")                 # 성공 메시지
    return bdir                                             # 빌드 디렉터리 반환


# --------------------------------------------------------------------------- #
# 실행 (xsim) + 결과 판정
# --------------------------------------------------------------------------- #
UVM_CNT = re.compile(r"^\s*(UVM_INFO|UVM_WARNING|UVM_ERROR|UVM_FATAL)\s*:\s*(\d+)\s*$", re.M)  # UVM 보고 요약의 "UVM_ERROR :  N" 줄 정규식
UVM_MSG = re.compile(r"^(UVM_ERROR|UVM_FATAL)\s+(?!:).*$", re.M)  # 요약 줄 "UVM_ERROR :  N"은 건너뜀


def judge(log: Path, uvm: bool, rc: int) -> dict:           # 실행 로그로 PASS/FAIL을 판정하는 함수
    txt = log.read_text(encoding="utf-8", errors="replace") if log.exists() else ""  # 로그 읽기 (없으면 빈 문자열)
    counts = {k: int(v) for k, v in UVM_CNT.findall(txt)}  # 마지막 요약을 사용
    tool_errs = [l for l in txt.splitlines() if re.match(r"^\s*(ERROR|FATAL_ERROR):", l)]  # 시뮬레이터 자체 오류 줄
    msg_lines = [m.group(0) for m in UVM_MSG.finditer(txt)]  # UVM_ERROR / UVM_FATAL 메시지 줄
    reasons = []                                            # 실패 이유 목록
    if rc == 124:                                           # 시간 초과였으면
        reasons.append("timeout")                           # 이유 추가
    elif rc != 0:                                           # 그 밖의 0이 아닌 종료 코드면
        reasons.append(f"xsim exit code {rc}")              # 이유 추가
    if tool_errs:                                           # 시뮬레이터 오류 줄이 있으면
        reasons.append(f"{len(tool_errs)} simulator ERROR lines")  # 이유 추가
    if uvm:                                                 # UVM TB면
        if "UVM Report Summary" not in txt:                 # UVM 보고 요약이 없으면 (중간에 끝남)
            reasons.append("no UVM Report Summary (sim did not finish cleanly)")  # 이유 추가
        if counts.get("UVM_ERROR", 0):                      # UVM_ERROR가 1개 이상이면
            reasons.append(f"UVM_ERROR={counts['UVM_ERROR']}")  # 이유 추가
        if counts.get("UVM_FATAL", 0):                      # UVM_FATAL이 1개 이상이면
            reasons.append(f"UVM_FATAL={counts['UVM_FATAL']}")  # 이유 추가
    m = re.search(r"Time:\s*([\d.]+\s*\w+)", txt)           # 시뮬레이션 끝 시각 찾기
    return {                                                # 판정 결과 사전 반환
        "status": "FAIL" if reasons else "PASS",            # 이유가 하나라도 있으면 FAIL
        "reasons": reasons,                                 # 실패 이유
        "uvm_counts": counts,                               # 심각도별 개수
        "first_errors": msg_lines[:10] or tool_errs[:10],   # 첫 오류 줄 최대 10개
        "n_uvm_error_lines": len(msg_lines),                # UVM 오류 메시지 줄 수
        "sim_end_time": m.group(1) if m else None,          # 시뮬레이션 끝 시각
    }                                                       # 사전 끝


def write_junit(path: Path, suite: str, case: str, res: dict, dur: float):  # JUnit XML 결과 파일을 쓰는 함수
    body = ""                                               # testcase 본문 (PASS면 비어 있음)
    if res["status"] == "FAIL" and not res.get("expected_fail"):  # 예상 밖 FAIL이면
        msg = escape("; ".join(res["reasons"]))             # 실패 이유를 이스케이프
        detail = escape("\n".join(res["first_errors"]))     # 첫 오류 줄들을 이스케이프
        body = f'<failure message="{msg}">{detail}</failure>'  # failure 요소
    elif res.get("expected_fail"):                          # 예상된 실패(XFAIL)면
        body = f'<system-out>{escape("XFAIL: " + "; ".join(res["reasons"]))}</system-out>'  # 실패가 아니라 system-out으로 기록
    fails = 1 if body.startswith("<failure") else 0         # failure 요소가 있으면 실패 1
    path.write_text(                                        # 파일 쓰기
        f'<?xml version="1.0" encoding="UTF-8"?>\n'         # XML 선언
        f'<testsuite name="{escape(suite)}" tests="1" failures="{fails}" time="{dur:.2f}">\n'  # testsuite 요소
        f'  <testcase classname="{escape(suite)}" name="{escape(case)}" time="{dur:.2f}">{body}</testcase>\n'  # testcase 요소
        f'</testsuite>\n', encoding="utf-8")                # testsuite 닫기


def run(cfg: dict, a) -> int:                               # run 명령: 빌드 후 테스트 실행
    tb = get_tb(cfg, a.tb)                                  # TB 설정
    bdir = OUT / a.tb / "build"                             # 빌드 디렉터리
    if not a.no_build or not (bdir / "build.json").exists():  # --no-build가 아니거나 빌드가 없으면
        build(cfg, a.tb, a.define, a.cov, a.wave)           # 빌드
    meta = json.loads((bdir / "build.json").read_text(encoding="utf-8"))  # 빌드 정보 읽기

    rc = 0                                                  # 가장 나쁜 종료 코드
    n = max(1, a.repeat)                                    # 반복 횟수 (최소 1)
    for i in range(n):                                      # 반복마다
        if a.seed == "random" or (n > 1 and i > 0):         # random이거나 두 번째 이후 반복이면
            seed = random.randint(1, 2**31 - 1)             # 랜덤 seed
        else:                                               # 아니면
            seed = int(a.seed)                              # 지정한 seed
        rc = max(rc, run_one(cfg, a, tb, bdir, meta, seed))  # 한 번 실행하고 종료 코드 갱신
    return rc                                               # 종료 코드 반환


def run_one(cfg: dict, a, tb: dict, bdir: Path, meta: dict, seed: int) -> int:  # 테스트 하나를 seed 하나로 실행하는 함수
    test = a.test or tb.get("default_test", "none")         # 테스트 이름 (없으면 TB 기본 테스트)
    rdir = OUT / a.tb / "runs" / f"{test}_{seed}"           # 실행 결과 디렉터리
    if rdir.exists():                                       # 이전 결과가 있으면
        shutil.rmtree(rdir, ignore_errors=True)             # 지움
    rdir.mkdir(parents=True)                                # 디렉터리 생성
    log = rdir / "run.log"                                  # 실행 로그 경로

    cmd = [tool(cfg, "xsim"), meta["snapshot"], "--log", str(log), "--sv_seed", str(seed)]  # xsim 명령: snapshot, 로그, seed
    if tb.get("uvm"):                                       # UVM TB면
        cmd += ["--testplusarg", f"UVM_TESTNAME={test}",    # 테스트 이름 plusarg
                "--testplusarg", f"UVM_VERBOSITY={a.verbosity}"]  # 로그 상세 수준 plusarg
    for p in a.plusarg:                                     # 추가 plusarg마다
        cmd += ["--testplusarg", p]                         # 인자 추가
    # 기능 커버리지(covergroup)는 항상 수집, 실행마다 DB 하나
    cmd += ["--cov_db_dir", str(rdir / "funccov"), "--cov_db_name", f"{test}_{seed}"]  # 기능 커버리지 DB 위치와 이름
    if a.wave:                                              # 파형을 원하면
        if not meta["wave"]:                                # snapshot이 파형 없이 빌드됐으면
            print("WARN: snapshot built without --wave; rebuild with --wave for waveforms")  # 경고
        tcl = rdir / "wave.tcl"                             # 파형 Tcl 스크립트 경로
        tcl.write_text("log_wave -recursive *\nrun all\nquit\n", encoding="utf-8")  # 모든 신호 기록 후 끝까지 실행
        cmd += ["--wdb", str(rdir / "wave.wdb"), "--tclbatch", str(tcl)]  # 파형 DB와 Tcl 배치 인자
    else:                                                   # 파형이 필요 없으면
        cmd += ["--runall"]                                 # 끝까지 실행

    # --isolate: snapshot 개인 사본을 써서 병렬 실행끼리 xsim.dir를 공유하지 않게 함
    cwd = bdir                                              # 기본 작업 디렉터리 = 빌드 디렉터리
    if a.isolate:                                           # 격리 실행이면
        shutil.copytree(bdir / "xsim.dir", rdir / "xsim.dir")  # xsim.dir을 실행 디렉터리로 복사
        cwd = rdir                                          # 거기서 실행
    t0 = time.time()                                        # 시작 시각
    rc = run_tool(cmd, cwd, timeout=a.timeout or cfg.get("default_timeout_s", 600))  # xsim 실행 (시간 제한 적용)
    dur = time.time() - t0                                  # 걸린 시간
    if a.isolate:                                           # 격리 실행이었으면
        shutil.rmtree(rdir / "xsim.dir", ignore_errors=True)  # 복사본 삭제

    res = judge(log, tb.get("uvm", False), rc)              # 로그로 판정
    # 예상된 실패: TB 전체("expect": "fail") 또는 테스트별로 추적 중인 RTL 버그
    known = tb.get("known_fail", {}).get(test)              # 이 테스트의 known_fail 사유
    expect_fail = tb.get("expect") == "fail" or known is not None  # 실패가 예상되는지
    if known:                                               # known_fail이면
        res["known_fail"] = known                           # 사유를 결과에 기록
    res["expected_fail"] = expect_fail and res["status"] == "FAIL"  # 예상대로 실패했는지
    ok = (res["status"] == "PASS") != expect_fail           # 기대와 결과가 맞으면 ok
    verdict = ("XFAIL" if res["expected_fail"] else         # 판정: XFAIL
               "XPASS(unexpected)" if expect_fail else res["status"])  # XPASS(예상 밖 통과), 또는 PASS/FAIL
    res.update({"tb": a.tb, "test": test, "seed": seed, "verdict": verdict, "ok": ok,  # 결과에 실행 정보 추가
                "duration_s": round(dur, 2), "log": str(log),  # 걸린 시간, 로그 경로
                "rerun": f"python scripts/sim.py run --tb {a.tb} --test {test} --seed {seed}"  # 다시 실행하는 명령
                         + "".join(f" --define {d}" for d in a.define)  # define 인자 포함
                         + "".join(f" --plusarg {q}" for q in a.plusarg)})  # plusarg 인자 포함
    (rdir / "result.json").write_text(json.dumps(res, indent=2), encoding="utf-8")  # result.json 저장
    write_junit(rdir / "junit.xml", a.tb, f"{test}[seed={seed}]", res, dur)  # junit.xml 저장

    print("=" * 72)                                         # 구분선
    print(f"[{verdict}] tb={a.tb} test={test} seed={seed} ({dur:.1f}s)")  # 판정 요약 줄
    if known:                                               # known_fail이면
        print(f"   known-fail: {known}")                    # 사유 출력
    for r in res["reasons"]:                                # 실패 이유마다
        print(f"   - {r}")                                  # 출력
    for e in res["first_errors"][:3]:                       # 첫 오류 줄 3개
        print(f"   > {e[:200]}")                            # 200자까지 출력
    print(f"   log   : {log}")                              # 로그 경로
    print(f"   rerun : {res['rerun']}")                     # 다시 실행 명령
    print("=" * 72)                                         # 구분선
    return 0 if ok else 1                                   # 기대대로면 0, 아니면 1


# --------------------------------------------------------------------------- #
# 커버리지 보고서 (xcrg)
# --------------------------------------------------------------------------- #
def cov_report(cfg: dict, a) -> int:                        # cov-report 명령: 커버리지 보고서 생성
    bdir = OUT / a.tb / "build"                             # 빌드 디렉터리
    meta_p = bdir / "build.json"                            # 빌드 정보 파일
    if not meta_p.exists():                                 # 빌드가 없으면
        sys.exit(f"ERROR: no build for {a.tb}. Run: sim.py run --tb {a.tb}")  # 오류 종료
    meta = json.loads(meta_p.read_text())                   # 빌드 정보 읽기
    snap = meta["snapshot"]                                 # snapshot 이름
    rep = OUT / a.tb / "cov"                                # 보고서 디렉터리
    # xcrg는 기존 텍스트 보고서를 바꾸지 않고 뒤에 덧붙이므로, 옛 점수가 파일
    # 맨 위에 남음: 항상 빈 보고서 디렉터리에서 시작
    shutil.rmtree(rep, ignore_errors=True)                  # 보고서 디렉터리 지움
    rep.mkdir(parents=True, exist_ok=True)                  # 다시 생성
    # 참고: xcrg.bat는 성공해도 127로 끝나므로 (2022.2) 로그/출력으로 판정.
    def xcrg_ok(log: Path, out_dir: Path) -> bool:          # xcrg 결과가 정상인지 확인하는 함수
        txt = log.read_text(encoding="utf-8", errors="replace") if log.exists() else ""  # 로그 읽기
        bad = "could not be completed" in txt or re.search(r"^\s*ERROR", txt, re.M)  # 실패 문구나 ERROR 줄이 있는지
        return out_dir.exists() and not bad                 # 출력 폴더가 있고 오류가 없으면 정상

    ok = True                                               # 전체 성공 여부
    if meta["cov"]:                                         # 코드 커버리지를 켠 빌드면
        run_tool([tool(cfg, "xcrg"), "-report_format", "html",  # xcrg 코드 커버리지 보고서 (HTML)
                  "-cc_dir", str(bdir / "codecov"), "-cc_db", snap,  # 코드 커버리지 DB
                  "-cc_report", str(rep / "code"), "-log", str(rep / "xcrg_code.log")], bdir)  # 보고서 위치와 로그
        ok &= xcrg_ok(rep / "xcrg_code.log", rep / "code")  # 결과 확인
    else:                                                   # 코드 커버리지가 없으면
        print("INFO: build has no code coverage (use run --cov); functional coverage only")  # 안내 출력
    # 모든 실행의 기능 커버리지를 합침 (covergroup이 있을 때만 존재)
    runs = sorted((OUT / a.tb / "runs").glob("*/funccov/xsim.covdb"))  # 모든 실행의 기능 커버리지 DB 목록
    if runs:                                                # 하나라도 있으면
        lst = rep / "funccov_dbs.txt"                       # DB 목록 파일
        lst.write_text("\n".join(p.as_posix() for p in runs), encoding="utf-8")  # 한 줄에 하나씩 기록
        run_tool([tool(cfg, "xcrg"), "-report_format", "all", "-file", str(lst),   # html + 텍스트
                  "-merge_dir", str(rep / "merged"), "-report_dir", str(rep / "func"),  # 병합 위치, 보고서 위치
                  "-log", str(rep / "xcrg_func.log")], bdir)  # 로그
        ok &= xcrg_ok(rep / "xcrg_func.log", rep / "func")  # 결과 확인
    else:                                                   # DB가 없으면
        print("INFO: no functional coverage DBs (no covergroups yet)")  # 안내 출력
    print(f"Coverage report {'OK' if ok else 'FAILED'}: {rep}")  # 결과 출력
    return 0 if ok else 2                                   # 성공 0, 실패 2


# --------------------------------------------------------------------------- #
def main() -> int:                                          # 진입점
    cfg = load_cfg()                                        # 설정 읽기
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)  # 인자 파서 (도움말에 모듈 설명 그대로)
    sub = ap.add_subparsers(dest="cmd", required=True)      # 하위 명령 (반드시 하나)

    sub.add_parser("list", help="등록된 테스트벤치 목록")             # list 명령

    p = sub.add_parser("lint", help="컴파일 + elaborate만")     # lint 명령
    p.add_argument("--tb", required=True)                   # TB 이름 (필수)
    p.add_argument("--define", action="append", default=[])  # 추가 define (여러 번 가능)

    p = sub.add_parser("run", help="빌드 (--no-build가 아니면) 후 테스트/seed 하나 시뮬레이션")  # run 명령
    p.add_argument("--tb", required=True)                   # TB 이름 (필수)
    p.add_argument("--test")                                # 테스트 이름
    p.add_argument("--seed", default="1")                   # seed (숫자 또는 random)
    p.add_argument("--define", action="append", default=[])  # 추가 define
    p.add_argument("--plusarg", action="append", default=[])  # 추가 plusarg
    p.add_argument("--verbosity", default="UVM_LOW")        # UVM 로그 상세 수준
    p.add_argument("--timeout", type=int)                   # 시간 제한 (초)
    p.add_argument("--cov", action="store_true")            # 코드 커버리지 켜기
    p.add_argument("--wave", action="store_true")           # 파형 기록
    p.add_argument("--no-build", action="store_true")       # 빌드 건너뛰기
    p.add_argument("--repeat", type=int, default=1, help="seed N개 실행 (첫째 = --seed, 나머지는 랜덤)")  # 반복 횟수
    p.add_argument("--isolate", action="store_true", help="snapshot 개인 사본에서 실행 (병렬 실행에 안전)")  # 격리 실행

    p = sub.add_parser("cov-report", help="코드 + 기능 커버리지 HTML 생성")  # cov-report 명령
    p.add_argument("--tb", required=True)                   # TB 이름 (필수)

    a = ap.parse_args()                                     # 인자 파싱
    if a.cmd == "list":                                     # list면
        for k, v in cfg["tbs"].items():                     # TB마다
            print(f"{k:18s} {v.get('desc', '')}")           # 이름과 설명 출력
        return 0                                            # 성공
    if a.cmd == "lint":                                     # lint면
        build(cfg, a.tb, a.define, cov=False, wave=False)   # 커버리지/파형 없이 빌드만
        return 0                                            # 성공 (실패하면 build 안에서 종료)
    if a.cmd == "run":                                      # run이면
        return run(cfg, a)                                  # 실행
    if a.cmd == "cov-report":                               # cov-report면
        return cov_report(cfg, a)                           # 보고서 생성
    return 2                                                # 알 수 없는 명령


if __name__ == "__main__":                                  # 스크립트로 실행될 때만
    sys.exit(main())                                        # main의 반환값을 종료 코드로
