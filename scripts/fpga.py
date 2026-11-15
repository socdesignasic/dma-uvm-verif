#!/usr/bin/env python3
"""
fpga.py - FPGA 구현 흐름의 단일 진입점 (P6, "CD").

  python scripts/fpga.py ooc                 # dma_ip_top 단독: 100 MHz 합성+배치배선, 타이밍/사용량
  python scripts/fpga.py ooc --period 7.5    # 133 MHz에서 여유 확인
  python scripts/fpga.py system              # PS7 + DMA block design -> 비트스트림 + XSA
  python scripts/fpga.py system --impl-strategy default   # Vivado 기본 구현 전략

출력 (out/fpga/<mode>/ 아래):
  result.json        판정, WNS/WHS, 사용량, 결과물 경로, bit/xsa의 sha256
  timing_summary.rpt, utilization.rpt, vivado.log
  design_1_wrapper.bit / .xsa      (system만. XSA는 Vitis가 읽는 파일)

종료 코드: 0 = 빌드 성공 + 타이밍 만족, 1 = 타이밍 위반, 2 = 도구/빌드 오류.
RTL은 HW/에서만 가져옵니다. IP repo는 여기서 HW/ + ci/vivado/ip/ 메타데이터로 조립하므로,
비트스트림은 항상 검증한 RTL 그대로 빌드됩니다.
"""
from __future__ import annotations                          # 타입 힌트를 문자열로 지연 평가

import argparse                                             # 명령줄 인자 파싱
import hashlib                                              # 비트스트림/XSA의 sha256 계산
import json                                                 # result.json 쓰기
import os                                                   # 환경 변수, OS 종류 확인
import re                                                   # 정규식 (보고서 파싱)
import shutil                                               # 디렉터리 복사/삭제
import subprocess                                           # Vivado, git 실행
import sys                                                  # 종료 코드
import time                                                 # 걸린 시간, 시각 문자열
from pathlib import Path                                    # 경로 처리

# 한글 출력이 Jenkins/MCP(UTF-8로 읽음)에서 깨지지 않도록 출력 인코딩을 UTF-8로 고정
for _s in (sys.stdout, sys.stderr):                         # 표준 출력과 표준 오류 각각
    if hasattr(_s, "reconfigure"):                          # reconfigure를 지원하면
        _s.reconfigure(encoding="utf-8", errors="replace")  # UTF-8로 바꾸고, 못 바꾸는 문자는 ?로

ROOT = Path(__file__).resolve().parent.parent               # 저장소 루트
OUT = ROOT / "out" / "fpga"                                 # FPGA 결과 디렉터리
VIV = ROOT / "ci" / "vivado"                                # Vivado Tcl 스크립트 디렉터리
LUT_LIMIT = {"Slice LUTs": 53200, "Slice Registers": 106400, "Block RAM Tile": 140, "DSPs": 220}  # xc7z020의 자원 총량 (사용률 계산용)


def vivado() -> str:                                        # Vivado 실행 파일 경로를 돌려주는 함수
    env = os.environ.get("XILINX_VIVADO")                   # XILINX_VIVADO 환경 변수
    base = Path(env) if env else Path("C:/Xilinx/Vivado/2022.2")  # 없으면 기본 설치 위치
    exe = base / "bin" / ("vivado.bat" if os.name == "nt" else "vivado")  # Windows면 .bat, 아니면 실행 파일
    if not exe.exists():                                    # 없으면
        sys.exit(f"ERROR: Vivado not found at {exe} (set XILINX_VIVADO)")  # 오류 종료
    return str(exe)                                         # 문자열로 반환


def run_vivado(tcl: Path, out: Path, tclargs: list[str], timeout: int) -> int:  # Vivado를 batch 모드로 실행하는 함수
    log = out / "vivado.log"                                # Vivado 로그 경로
    cmd = [vivado(), "-mode", "batch", "-nojournal", "-log", str(log), "-source", str(tcl),  # batch 모드, journal 없음, 로그, Tcl 스크립트
           "-tclargs", *tclargs]                            # Tcl 스크립트에 넘길 인자
    # Windows .bat wrapper: 따옴표/슬래시 규칙은 sim.py와 같음
    line = " ".join(f'"{c}"' if re.search(r"[\s=,;&()^]", c) else c  # Windows 명령줄 문자열로 변환 (특수문자 있으면 따옴표)
                    for c in (x.replace("\\", "/") for x in cmd))  # 역슬래시를 슬래시로
    print(">>", line, flush=True)                           # 실행할 명령 출력
    try:                                                    # 시간 제한 처리
        return subprocess.run(line if os.name == "nt" else cmd, cwd=out, timeout=timeout).returncode  # 실행하고 종료 코드 반환
    except subprocess.TimeoutExpired:                       # 시간 초과면
        print(f"ERROR: vivado timeout after {timeout}s")    # 오류 출력
        return 124                                          # timeout 관례 종료 코드 124


def parse_result(out: Path) -> dict:                        # Tcl이 남긴 결과와 보고서를 읽는 함수
    r = {}                                                  # 결과 사전
    p = out / "result.txt"                                  # Tcl이 쓴 key=value 파일
    if p.exists():                                          # 있으면
        for l in p.read_text().splitlines():                # 줄마다
            k, _, v = l.partition("=")                      # = 앞뒤로 나눔
            r[k.strip().lower()] = v.strip()                # 소문자 키로 저장
    for k in ("wns", "whs", "period"):                      # 숫자여야 하는 키마다
        try:                                                # 숫자로 변환 시도
            r[k] = float(r[k])                              # float로 바꿈
        except (KeyError, ValueError):                      # 없거나 숫자가 아니면
            r.pop(k, None)                                  # 지움
    util = {}                                               # 자원 사용량
    u = out / "utilization.rpt"                             # 사용량 보고서
    if u.exists():                                          # 있으면
        for l in u.read_text(errors="replace").splitlines():  # 줄마다
            m = re.match(r"\|\s*(Slice LUTs|Slice Registers|Block RAM Tile|DSPs)\*?\s*\|\s*([\d.]+)\s*\|", l)  # LUT/레지스터/BRAM/DSP 행에서 사용량 추출
            if m and m.group(1) not in util:                # 처음 나온 값만 사용
                util[m.group(1)] = float(m.group(2))        # 사용량 저장
    r["utilization"] = {k: {"used": v, "pct": round(100 * v / LUT_LIMIT[k], 2)} for k, v in util.items()}  # 사용량과 사용률(%)
    log = out / "vivado.log"                                # Vivado 로그
    if log.exists():                                        # 있으면
        txt = log.read_text(errors="replace")               # 로그 읽기
        r["errors"] = re.findall(r"^ERROR: .*$", txt, re.M)[:10]  # ERROR 줄 최대 10개
        r["critical_warnings"] = len(re.findall(r"^CRITICAL WARNING:", txt, re.M))  # CRITICAL WARNING 개수
    return r                                                # 결과 반환


def sha256(p: Path) -> str:                                 # 파일의 sha256을 계산하는 함수
    h = hashlib.sha256()                                    # 해시 객체
    with open(p, "rb") as f:                                # 바이너리로 열기
        for chunk in iter(lambda: f.read(1 << 20), b""):    # 1MB씩 읽음
            h.update(chunk)                                 # 해시에 더함
    return h.hexdigest()                                    # 16진수 문자열 반환


def assemble_ip_repo(dst: Path) -> Path:                    # IP repo를 조립하는 함수
    """IP repo = 패키징 메타데이터 (component.xml, xgui) + HW/의 RTL 트리."""  # 함수 설명
    ip = dst / "dma_ip_top"                           # IP 디렉터리
    shutil.rmtree(dst, ignore_errors=True)                  # 이전 repo 삭제
    shutil.copytree(VIV / "ip" / "dma_ip_top", ip)    # 패키징 메타데이터 복사
    for sub in ("dma_ip", "peri_ip"):           # RTL 하위 디렉터리마다
        shutil.copytree(ROOT / "HW" / sub, ip / sub)        # HW/에서 복사
    # IP가 선언한 파일은 모두 있어야 함 (RTL 파일 이름이 바뀌어 패키징이 깨지는 경우를 잡음)
    xml = (ip / "component.xml").read_text(encoding="utf-8")  # component.xml 읽기
    missing = [f for f in set(re.findall(r"<spirit:name>([\w/]+\.v)</spirit:name>", xml)) if not (ip / f).exists()]  # 선언된 .v 파일 중 없는 것
    if missing:                                             # 하나라도 없으면
        sys.exit(f"ERROR: component.xml references missing RTL: {missing}")  # 오류 종료
    return dst                                              # repo 경로 반환


def git_rev() -> str:                                       # 현재 git 커밋을 돌려주는 함수
    try:                                                    # git이 없을 수 있음
        return subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True,  # 짧은 커밋 해시
                              text=True).stdout.strip()     # 출력 문자열 정리
    except OSError:                                         # git 실행 실패면
        return "unknown"                                    # unknown


def main() -> int:                                          # 진입점
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)  # 인자 파서
    sub = ap.add_subparsers(dest="mode", required=True)     # 하위 명령 (ooc 또는 system)
    p = sub.add_parser("ooc", help="dma_ip_top 단독(out-of-context) 합성+배치배선")  # ooc 명령
    p.add_argument("--period", type=float, default=10.0, help="ap_clk 주기, ns 단위 (기본 10 = 100 MHz)")  # 클럭 주기
    p = sub.add_parser("system", help="block design -> 비트스트림 + XSA")  # system 명령
    p.add_argument("--jobs", type=int, default=6)           # 병렬 작업 수
    p.add_argument("--impl-strategy", default="Performance_ExplorePostRoutePhysOpt",  # 구현 전략
                   help="Vivado impl_1 전략 ('default' = Vivado 기본값). BUGS.md NOTE-001 참고")  # 도움말
    a = ap.parse_args()                                     # 인자 파싱

    out = OUT / a.mode                                      # 모드별 결과 디렉터리
    shutil.rmtree(out, ignore_errors=True)                  # 이전 결과 삭제
    out.mkdir(parents=True)                                 # 다시 생성
    t0 = time.time()                                        # 시작 시각
    if a.mode == "ooc":                                     # ooc면
        rc = run_vivado(VIV / "ooc.tcl", out, [str(out), f"{a.period:g}"], timeout=3600)  # ooc.tcl 실행 (최대 1시간)
    else:                                                   # system이면
        repo = assemble_ip_repo(OUT / "ip_repo")            # IP repo 조립
        rc = run_vivado(VIV / "build_system.tcl", out, [str(out), str(repo), str(a.jobs), a.impl_strategy],  # build_system.tcl 실행
                        timeout=4 * 3600)                   # 최대 4시간

    res = parse_result(out)                                 # 결과 파싱
    res.update({"mode": a.mode, "git": git_rev(), "vivado_rc": rc,  # 모드, git 커밋, Vivado 종료 코드
                "elapsed_s": round(time.time() - t0), "time": time.strftime("%Y-%m-%d %H:%M:%S")})  # 걸린 시간, 시각
    if a.mode == "system":                                  # system이면
        arts = {}                                           # 결과물 정보
        for name in ("design_1_wrapper.bit", "design_1_wrapper.xsa"):  # 비트스트림과 XSA마다
            f = out / name                                  # 파일 경로
            if f.exists():                                  # 있으면
                arts[name] = {"path": str(f), "bytes": f.stat().st_size, "sha256": sha256(f)}  # 경로, 크기, sha256 기록
        res["artifacts"] = arts                             # 결과에 추가
    if rc != 0 or "wns" not in res or (a.mode == "system" and len(res.get("artifacts", {})) < 2):  # Vivado 실패, 타이밍 없음, 결과물 부족이면
        res["verdict"], code = "BUILD_FAIL", 2              # 빌드 실패, 종료 코드 2
    elif res["wns"] < 0 or res.get("whs", 0) < 0:           # setup 또는 hold 여유가 음수면
        res["verdict"], code = "TIMING_FAIL", 1             # 타이밍 실패, 종료 코드 1
    else:                                                   # 모두 정상이면
        res["verdict"], code = "PASS", 0                    # PASS, 종료 코드 0
    (out / "result.json").write_text(json.dumps(res, indent=2), encoding="utf-8")  # result.json 저장

    print("=" * 72)                                         # 구분선
    print(f"[{res['verdict']}] fpga {a.mode}  WNS={res.get('wns')} ns  WHS={res.get('whs')} ns"  # 판정과 WNS/WHS
          f"  ({res['elapsed_s']}s, git {res['git']})")     # 걸린 시간과 git 커밋
    for k, v in res.get("utilization", {}).items():         # 자원마다
        print(f"   {k:16s} {v['used']:>8g}  ({v['pct']}%)")  # 사용량과 사용률 출력
    for k, v in res.get("artifacts", {}).items():           # 결과물마다
        print(f"   {k}: {v['bytes']} bytes sha256={v['sha256'][:16]}...")  # 크기와 sha256 앞 16자리 출력
    for e in res.get("errors", [])[:5]:                     # 오류 줄 최대 5개
        print(f"   > {e[:200]}")                            # 200자까지 출력
    print(f"   result: {out / 'result.json'}")              # 결과 파일 경로
    print("=" * 72)                                         # 구분선
    return code                                             # 종료 코드 반환


if __name__ == "__main__":                                  # 스크립트로 실행될 때만
    sys.exit(main())                                        # main의 반환값을 종료 코드로
