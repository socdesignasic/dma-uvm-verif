"""보드 시험: Zybo에 비트스트림을 올리고 DMA mem copy를 실제 DDR에서 실행해 결과를 확인.

xsdb(Vivado에 포함)로 JTAG를 통해 PS를 초기화하고 DMA 레지스터를 씁니다 (ci/vivado/board_test.tcl).
원본 데이터를 만들고, 읽어 온 대상 데이터를 기대값((원본 + add_val) & 0xFF, 바이트마다)과 비교합니다.

  python scripts/board.py                                  # 기본: out/fpga/system 의 XSA
  python scripts/board.py --xsa out/fpga/system_xc7z010/design_1_wrapper.xsa
"""
from __future__ import annotations                         # 타입 힌트를 문자열로 지연 평가

import argparse                                             # 명령줄 인자
import hashlib                                              # XSA 해시
import json                                                 # result.json 저장
import os                                                   # 환경 변수
import random                                               # 원본 데이터 생성
import re                                                   # xsdb 출력 파싱
import subprocess                                           # xsdb 실행
import sys                                                  # 종료 코드
import time                                                 # 시각
import zipfile                                              # XSA 풀기
from pathlib import Path                                    # 경로 처리

from common import ROOT, provenance, setup_utf8, tool     # 공통 모듈 (scripts/common.py)

setup_utf8()                                                # UTF-8 출력 (Windows 코드페이지 949 대비)
OUT = ROOT / "out" / "board"                                # 보드 시험 결과 디렉터리
TCL = ROOT / "ci" / "vivado" / "board_test.tcl"             # xsdb 스크립트
DDR = 0x10000000                                            # 시험에 쓰는 DDR 영역 시작 (mem_copy_test.c와 같음)

# 시험 목록: 이름, 원본 오프셋, 대상 오프셋, 바이트 수, 더할 값, 데이터 종류
CASES = [                                                   # 시험 목록 시작
    ("one_beat",   0x000000, 0x100000,       8,   1, "ramp"),  # 최소 전송 (1 beat)
    ("burst16",    0x000000, 0x100000,     128,   0, "rand"),  # 정확히 burst 하나 (16 beat)
    ("burst17",    0x000000, 0x100000,     136, 255, "rand"),  # burst 하나 + 1 beat
    ("page4k",     0x000000, 0x100000,    4096,   7, "rand"),  # 정확히 4KB
    ("cross4k",    0x000F80, 0x101F40,     512,   3, "rand"),  # 원본·대상 모두 4KB 경계를 넘음
    ("c_ref_64k",  0x000000, 0x010000,   65536,  42, "ramp"),  # mem_copy_test.c 방식 (dst = src + len)
    ("big_1m",     0x000000, 0x200000, 1 << 20, 200, "rand"),  # 1MB
]                                                           # 목록 끝


def xsdb() -> str:                                          # xsdb 실행 파일 경로를 돌려주는 함수
    return tool("xsdb")                                     # XILINX_VIVADO -> PATH -> 기본 위치 (common.tool)


def make_src(kind: str, n: int, seed: int) -> bytes:        # 원본 데이터를 만드는 함수
    if kind == "ramp":                                      # ramp면
        return bytes(i % 256 for i in range(n))             # mem_copy_test.c와 같은 0,1,2,... 패턴
    return random.Random(seed).randbytes(n)                 # 그 밖에는 seed 고정 랜덤


def main() -> int:                                          # 진입점
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)  # 인자 파서
    ap.add_argument("--xsa", default=str(ROOT / "out" / "fpga" / "system" / "design_1_wrapper.xsa"))  # XSA 경로
    ap.add_argument("--seed", type=int, default=1)          # 랜덤 데이터 seed
    ap.add_argument("--only", nargs="*", help="이 이름의 시험만 실행")  # 일부 시험만
    a = ap.parse_args()                                     # 인자 파싱

    xsa = Path(a.xsa).resolve()                             # XSA 절대 경로
    run = OUT / time.strftime("%Y%m%d_%H%M%S")              # 이번 실행 디렉터리
    hw = run / "hw"                                         # XSA를 풀 디렉터리
    hw.mkdir(parents=True)                                  # 생성
    with zipfile.ZipFile(xsa) as z:                         # XSA는 zip 파일
        z.extractall(hw)                                    # 비트스트림과 ps7_init.tcl을 꺼냄
    bit = next(hw.glob("*.bit"))                            # 비트스트림

    cases = [c for c in CASES if not a.only or c[0] in a.only]  # 실행할 시험
    exp = {}                                                # 시험 이름 -> 기대값
    with open(run / "cases.txt", "w", encoding="ascii") as f:  # xsdb에 줄 시험 목록
        for i, (name, so, do, n, add, kind) in enumerate(cases):  # 시험마다
            src = make_src(kind, n, a.seed * 1000 + i)      # 원본 데이터
            (run / f"{name}.src").write_bytes(src)          # 원본 파일
            (run / f"{name}.clr").write_bytes(b"\xa5" * n)  # 대상 초기값 (0xA5로 채움)
            exp[name] = bytes((b + add) & 0xFF for b in src)  # 기대값: 바이트마다 더하기 (8비트 lane, 올림 버림)
            f.write(f"{name} 0x{DDR + so:08x} 0x{DDR + do:08x} {n} {add}\n")  # 이름 원본 대상 크기 값

    cmd = [xsdb(), str(TCL), str(bit), str(hw / "ps7_init.tcl"), str(run / "cases.txt"), str(run)]  # xsdb 명령
    print("$", " ".join(cmd), flush=True)                   # 실행 명령 출력
    t0 = time.time()                                        # 시작 시각
    p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=1800)  # 실행 (최대 30분)
    log = p.stdout + p.stderr                               # 전체 출력
    (run / "xsdb.log").write_text(log, encoding="utf-8")    # 로그 저장

    jtag = re.search(r"^JTAG (.*)$", log, re.M)             # JTAG 체인 줄
    st = {m[0]: m for m in re.findall(r"^CASE (\S+) idle=(\d) status=(\S+) ctrl=(\S+) ms=(\d+)", log, re.M)}  # 시험별 상태
    results = []                                            # 결과 목록
    for name, so, do, n, add, kind in cases:                # 시험마다
        r = {"name": name, "bytes": n, "add": add, "src": hex(DDR + so), "dst": hex(DDR + do)}  # 기본 정보
        if name not in st:                                  # xsdb가 이 시험까지 못 갔으면
            r["verdict"] = "NO_RESULT"                      # 결과 없음
        else:                                               # 결과가 있으면
            _, idle, status, ctrl, ms = st[name]            # 상태 꺼내기
            got = (run / f"{name}.dst").read_bytes()        # 읽어 온 대상 데이터
            bad = [i for i in range(n) if got[i] != exp[name][i]]  # 틀린 바이트 위치
            r.update({"status": status, "ctrl": ctrl, "ms": int(ms), "idle_before": idle == "1",  # 상태, 레지스터, 시간
                      "mismatch": len(bad), "first_bad": bad[:5]})  # 틀린 개수와 처음 몇 개
            if bad:                                         # 틀린 바이트가 있으면
                i = bad[0]                                  # 첫 위치
                r["first_bad_detail"] = f"off={i} exp=0x{exp[name][i]:02x} got=0x{got[i]:02x}"  # 기대값과 실제값
            r["verdict"] = "PASS" if status == "DONE" and not bad else ("HANG" if status == "HANG" else "MISMATCH")  # 판정
        results.append(r)                                   # 목록에 추가

    summary = {"xsa": str(xsa), "jtag": jtag[1] if jtag else None, "seed": a.seed,  # 요약: XSA, 보드, seed
               "elapsed_s": round(time.time() - t0), "xsdb_rc": p.returncode, "results": results,  # 시간, 종료 코드, 결과
               "time": time.strftime("%Y-%m-%d %H:%M:%S"),  # 시각
               "xsa_sha256": hashlib.sha256(xsa.read_bytes()).hexdigest(),  # 보드에 올린 XSA (fpga.py system 결과와 대조)
               "provenance": provenance()}                  # 실행한 checkout의 커밋, HW/ 해시
    (run / "result.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")  # 저장

    print("=" * 72)                                         # 구분선
    print(f"board: {summary['jtag']}   xsa: {xsa.name}   ({summary['elapsed_s']}s)")  # 보드와 XSA
    for r in results:                                       # 시험마다
        extra = f"  {r.get('first_bad_detail', '')}" if r.get("mismatch") else ""  # 틀렸으면 첫 위치
        print(f"  [{r['verdict']:9s}] {r['name']:10s} {r['bytes']:>8d}B add={r['add']:<3d} "  # 판정, 이름, 크기, 값
              f"{r.get('ms', '-')!s:>5}ms ctrl={r.get('ctrl', '-')} mismatch={r.get('mismatch', '-')}{extra}")  # 시간, 레지스터, 틀린 수
    if not st:                                              # 시험 결과가 하나도 없으면
        print(log[-2000:])                                  # xsdb 출력 끝부분 출력
    print(f"  result: {run / 'result.json'}")               # 결과 파일
    print("=" * 72)                                         # 구분선
    return 0 if results and all(r["verdict"] == "PASS" for r in results) else 1  # 모두 PASS면 0


if __name__ == "__main__":                                  # 스크립트로 실행될 때만
    sys.exit(main())                                        # main의 반환값을 종료 코드로
