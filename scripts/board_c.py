"""C 보드 시험: ARM(Cortex-A9)에서 C 프로그램이 DMA를 구동하고 결과를 스스로 판정합니다.

scripts/board.py는 xsdb가 JTAG로 레지스터를 직접 쓰지만, 이 스크립트는 실제 소프트웨어 경로
(BSP, D-cache flush/invalidate, Xil_Out32)로 같은 7개 시험을 돌립니다.

  1. xsct(Vitis)로 XSA -> standalone BSP -> fw/dma_board_test/ ELF 빌드 (ci/vitis/build_app.tcl)
  2. xsdb로 비트스트림, PS 초기화, ELF 다운로드, 실행 (ci/vivado/board_run_elf.tcl)
  3. 프로그램이 DDR mailbox에 쓴 결과를 JTAG로 읽고, UART 출력(COM 포트)도 함께 저장
  4. mailbox와 UART의 판정이 서로 맞는지 확인

  python scripts/board_c.py                         # 기본: Zybo Z7-10 XSA, COM7
  python scripts/board_c.py --skip-build --com COM5
"""
from __future__ import annotations                         # 타입 힌트를 문자열로 지연 평가

import argparse                                             # 명령줄 인자
import hashlib                                              # XSA 해시
import json                                                 # result.json 저장
import os                                                   # 환경 변수
import re                                                   # 출력 파싱
import struct                                               # mailbox 바이너리 해석
import subprocess                                           # xsct, xsdb, PowerShell 실행
import sys                                                  # 종료 코드
import time                                                 # 시각
import zipfile                                              # XSA 풀기
from pathlib import Path                                    # 경로 처리

from common import ROOT, provenance, setup_utf8           # 공통 모듈 (scripts/common.py)
from common import tool as _tool                            # 도구 찾기

setup_utf8()                                                # UTF-8 출력 (Windows 코드페이지 949 대비)
OUT = ROOT / "out" / "board_c"                              # 결과 디렉터리
SRC = ROOT / "fw" / "dma_board_test"                        # C 소스
BUILD_TCL = ROOT / "ci" / "vitis" / "build_app.tcl"         # xsct 빌드 스크립트
RUN_TCL = ROOT / "ci" / "vivado" / "board_run_elf.tcl"      # xsdb 실행 스크립트
MAGIC, VERSION = 0xD0A7E570, 1                              # dma_board_test.c의 MBOX_MAGIC, MBOX_VERSION
STATUS = {0: "PASS", 1: "MISMATCH", 2: "HANG", 3: "NOT_IDLE"}  # 판정 코드
HDR = struct.Struct("<6I")                                  # mailbox 머리: magic version n_cases n_pass done cps
REC = struct.Struct("<16s10I")                              # 시험 결과 하나 (result_t, 56바이트)

# UART 수신: pyserial 없이 .NET SerialPort로 읽어 표준 출력으로 내보냄 (ALL_DONE 또는 시간 초과까지)
UART_PS = r"""
$p = New-Object System.IO.Ports.SerialPort '{port}',115200,'None',8,'One'
$p.ReadTimeout = 500; $p.Open(); $p.DiscardInBuffer()
[Console]::Out.WriteLine('UART_OPEN'); [Console]::Out.Flush()
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt {secs}) {{
  try {{ $l = $p.ReadLine().TrimEnd("`r"); [Console]::Out.WriteLine($l); [Console]::Out.Flush()
        if ($l -match 'ALL_DONE') {{ break }} }} catch [TimeoutException] {{ }}
}}
$p.Close()
"""


def tool(name: str, sub: str) -> str:                       # Xilinx 도구 경로 (Windows는 .bat)
    return _tool(name, sub)                                 # XILINX_VIVADO / XILINX_VITIS -> PATH -> 기본 위치


def build(xsa: Path, ws: Path) -> Path:                     # ELF 빌드
    cmd = [tool("xsct", "Vitis"), str(BUILD_TCL), str(xsa), str(SRC), str(ws)]  # xsct 명령
    print("$", " ".join(cmd), flush=True)                   # 실행 명령 출력
    p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=1800)  # 실행
    (OUT / "build.log").write_text(p.stdout + p.stderr, encoding="utf-8")  # 로그 저장
    m = re.search(r"^ELF (.+)$", p.stdout, re.M)            # ELF 경로 줄
    if p.returncode or not m:                               # 실패면
        print((p.stdout + p.stderr)[-3000:])                # 로그 끝부분
        raise SystemExit("build failed")                    # 중단
    return Path(m[1].strip())                               # ELF 경로


def parse_mbox(raw: bytes) -> dict:                         # mailbox 바이너리 해석
    magic, ver, n, n_pass, done, cps = HDR.unpack_from(raw, 0)  # 머리
    if magic != MAGIC or ver != VERSION:                    # 다른 프로그램의 데이터면
        return {"valid": False, "magic": hex(magic)}        # 무효
    recs = []                                               # 시험 결과 목록
    for i in range(n):                                      # 시험마다
        f = REC.unpack_from(raw, HDR.size + i * REC.size)   # 한 칸 해석
        name = f[0].split(b"\0")[0].decode("ascii", "replace")  # 이름
        bytes_, add, st, mism, first, eg, hw, sw, ctrl, idle = f[1:]  # 나머지 필드
        r = {"name": name, "bytes": bytes_, "add": add, "verdict": STATUS.get(st, f"?{st}"),  # 기본 정보
             "mismatch": mism, "idle_before": bool(idle), "ctrl": f"0x{ctrl:08x}",  # 틀린 수, 상태
             "hw_us": round(hw / cps * 1e6, 2), "sw_memcpy_us": round(sw / cps * 1e6, 2)}  # 시간
        if mism:                                            # 틀렸으면
            r["first_bad_detail"] = f"off={first} exp=0x{eg >> 8 & 0xFF:02x} got=0x{eg & 0xFF:02x}"  # 첫 위치
        if st == 0 and hw:                                  # PASS면 처리량 계산
            r["hw_MBps"] = round(bytes_ / (hw / cps) / 1e6, 1)  # DMA (폴링 지연 포함)
            r["sw_MBps"] = round(bytes_ / (sw / cps) / 1e6, 1) if sw else None  # CPU memcpy
        recs.append(r)                                      # 추가
    return {"valid": True, "n_cases": n, "n_pass": n_pass, "done": bool(done), "timer_hz": cps, "results": recs}  # 요약


def main() -> int:                                          # 진입점
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)  # 인자 파서
    ap.add_argument("--xsa", default=str(ROOT / "out" / "fpga" / "system_xc7z010" / "design_1_wrapper.xsa"))  # XSA
    ap.add_argument("--com", default="COM7", help="Zybo USB-UART 포트")  # UART 포트
    ap.add_argument("--skip-build", action="store_true", help="이전에 만든 ELF 사용")  # 빌드 생략
    ap.add_argument("--timeout", type=int, default=60, help="프로그램 완료 대기 (초)")  # 실행 제한
    a = ap.parse_args()                                     # 인자 파싱

    xsa = Path(a.xsa).resolve()                             # XSA 절대 경로
    ws = OUT / "ws"                                         # Vitis workspace
    run = OUT / time.strftime("%Y%m%d_%H%M%S")              # 이번 실행 디렉터리
    hw = run / "hw"                                         # XSA를 풀 디렉터리
    hw.mkdir(parents=True)                                  # 생성
    with zipfile.ZipFile(xsa) as z:                         # XSA는 zip 파일
        z.extractall(hw)                                    # 비트스트림과 ps7_init.tcl
    bit = next(hw.glob("*.bit"))                            # 비트스트림

    elf = ws / "dma_board_test" / "Release" / "dma_board_test.elf"  # 기본 ELF 위치
    if not a.skip_build or not elf.exists():                # 빌드가 필요하면
        elf = build(xsa, ws)                                # 빌드

    uart = subprocess.Popen(                                # UART 수신 시작 (프로그램 실행 전에 열어 둠)
        ["powershell", "-NoProfile", "-Command", UART_PS.format(port=a.com, secs=a.timeout + 60)],  # PowerShell
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace")  # 출력 받기
    first = uart.stdout.readline()                          # 포트가 열렸는지 확인
    if "UART_OPEN" not in first:                            # 못 열었으면
        print(f"UART {a.com} 열기 실패: {first.strip()} (mailbox만으로 판정)", flush=True)  # 경고

    mbox_file = run / "mbox.bin"                            # mailbox 저장 파일
    cmd = [tool("xsdb", "Vivado"), str(RUN_TCL), str(bit), str(hw / "ps7_init.tcl"), str(elf), str(mbox_file), str(a.timeout)]  # xsdb
    print("$", " ".join(cmd), flush=True)                   # 실행 명령 출력
    t0 = time.time()                                        # 시작 시각
    p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=a.timeout + 300)  # 실행
    (run / "xsdb.log").write_text(p.stdout + p.stderr, encoding="utf-8")  # 로그 저장

    try:                                                    # UART 출력 마저 받기
        uart_out, _ = uart.communicate(timeout=15)          # ALL_DONE을 이미 받았으면 곧 끝남
    except subprocess.TimeoutExpired:                       # 안 끝나면
        uart.kill()                                         # 강제 종료
        uart_out, _ = uart.communicate()                    # 받은 만큼
    uart_log = uart_out if "UART_OPEN" in first else ""     # 포트가 열렸을 때만 의미 있음
    (run / "uart.log").write_text(uart_log, encoding="utf-8")  # 저장

    mb = parse_mbox(mbox_file.read_bytes()) if mbox_file.exists() else {"valid": False}  # mailbox 해석
    uart_st = dict(re.findall(r"^CASE (\S+) .*?status=(\S+)", uart_log, re.M))  # UART의 시험별 판정
    agree = None                                            # mailbox와 UART 일치 여부
    if mb.get("valid") and uart_st:                         # 둘 다 있으면
        agree = all(uart_st.get(r["name"]) == r["verdict"] for r in mb["results"])  # 모든 시험이 같은지
    results = mb.get("results", [])                         # 시험 결과
    ok = bool(mb.get("valid") and mb.get("done") and results and all(r["verdict"] == "PASS" for r in results)  # 전부 PASS
              and agree is not False)                       # UART와 어긋나지 않음

    jtag = re.search(r"^RUN done=(\d) secs=(\d+)", p.stdout, re.M)  # 실행 요약 줄
    summary = {"xsa": str(xsa), "elf": str(elf), "com": a.com, "xsdb_rc": p.returncode,  # 입력과 도구 상태
               "program_done": jtag[1] == "1" if jtag else False, "elapsed_s": round(time.time() - t0),  # 완료 여부, 시간
               "uart_agrees_with_mailbox": agree, "verdict": "PASS" if ok else "FAIL",  # 일치, 전체 판정
               "mailbox": mb, "time": time.strftime("%Y-%m-%d %H:%M:%S"),  # mailbox 내용, 시각
               "xsa_sha256": hashlib.sha256(xsa.read_bytes()).hexdigest(),  # 보드에 올린 XSA (fpga.py system 결과와 대조)
               "provenance": provenance()}                  # 실행한 checkout의 커밋, HW/ 해시
    (run / "result.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")  # 저장

    print("=" * 78)                                         # 구분선
    print(f"C on ARM  xsa: {xsa.parent.name}/{xsa.name}  uart: {a.com} ({'agree' if agree else agree})")  # 개요
    for r in results:                                       # 시험마다
        extra = f"  {r['first_bad_detail']}" if r.get("mismatch") else ""  # 틀렸으면 첫 위치
        print(f"  [{r['verdict']:8s}] {r['name']:10s} {r['bytes']:>8d}B add={r['add']:<3d} "  # 판정, 이름, 크기, 값
              f"dma {r['hw_us']:>9.2f}us ({r.get('hw_MBps', '-')!s:>6} MB/s)  "  # DMA 시간
              f"memcpy {r['sw_memcpy_us']:>9.2f}us ({r.get('sw_MBps', '-')!s:>6} MB/s){extra}")  # CPU 시간
    if not results:                                         # 결과가 없으면
        print((p.stdout + p.stderr)[-2000:])                # xsdb 출력 끝부분
        print(uart_log[-1000:])                             # UART 끝부분
    print(f"  verdict: {summary['verdict']}   result: {run / 'result.json'}")  # 전체 판정
    print("=" * 78)                                         # 구분선
    return 0 if ok else 1                                   # PASS면 0


if __name__ == "__main__":                                  # 스크립트로 실행될 때만
    sys.exit(main())                                        # main의 반환값을 종료 코드로
