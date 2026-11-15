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
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

# 한글 출력이 Jenkins/MCP(UTF-8로 읽음)에서 깨지지 않도록 출력 인코딩을 UTF-8로 고정
for _s in (sys.stdout, sys.stderr):
    if hasattr(_s, "reconfigure"):
        _s.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "out" / "fpga"
VIV = ROOT / "ci" / "vivado"
LUT_LIMIT = {"Slice LUTs": 53200, "Slice Registers": 106400, "Block RAM Tile": 140, "DSPs": 220}


def vivado() -> str:
    env = os.environ.get("XILINX_VIVADO")
    base = Path(env) if env else Path("C:/Xilinx/Vivado/2022.2")
    exe = base / "bin" / ("vivado.bat" if os.name == "nt" else "vivado")
    if not exe.exists():
        sys.exit(f"ERROR: Vivado not found at {exe} (set XILINX_VIVADO)")
    return str(exe)


def run_vivado(tcl: Path, out: Path, tclargs: list[str], timeout: int) -> int:
    log = out / "vivado.log"
    cmd = [vivado(), "-mode", "batch", "-nojournal", "-log", str(log), "-source", str(tcl),
           "-tclargs", *tclargs]
    # Windows .bat wrapper: 따옴표/슬래시 규칙은 sim.py와 같음
    line = " ".join(f'"{c}"' if re.search(r"[\s=,;&()^]", c) else c
                    for c in (x.replace("\\", "/") for x in cmd))
    print(">>", line, flush=True)
    try:
        return subprocess.run(line if os.name == "nt" else cmd, cwd=out, timeout=timeout).returncode
    except subprocess.TimeoutExpired:
        print(f"ERROR: vivado timeout after {timeout}s")
        return 124


def parse_result(out: Path) -> dict:
    r = {}
    p = out / "result.txt"
    if p.exists():
        for l in p.read_text().splitlines():
            k, _, v = l.partition("=")
            r[k.strip().lower()] = v.strip()
    for k in ("wns", "whs", "period"):
        try:
            r[k] = float(r[k])
        except (KeyError, ValueError):
            r.pop(k, None)
    util = {}
    u = out / "utilization.rpt"
    if u.exists():
        for l in u.read_text(errors="replace").splitlines():
            m = re.match(r"\|\s*(Slice LUTs|Slice Registers|Block RAM Tile|DSPs)\*?\s*\|\s*([\d.]+)\s*\|", l)
            if m and m.group(1) not in util:
                util[m.group(1)] = float(m.group(2))
    r["utilization"] = {k: {"used": v, "pct": round(100 * v / LUT_LIMIT[k], 2)} for k, v in util.items()}
    log = out / "vivado.log"
    if log.exists():
        txt = log.read_text(errors="replace")
        r["errors"] = re.findall(r"^ERROR: .*$", txt, re.M)[:10]
        r["critical_warnings"] = len(re.findall(r"^CRITICAL WARNING:", txt, re.M))
    return r


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def assemble_ip_repo(dst: Path) -> Path:
    """IP repo = 패키징 메타데이터 (component.xml, xgui) + HW/의 RTL 트리."""
    ip = dst / "dma_ip_top"
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(VIV / "ip" / "dma_ip_top", ip)
    for sub in ("dma_ip", "peri_ip"):
        shutil.copytree(ROOT / "HW" / sub, ip / sub)
    # IP가 선언한 파일은 모두 있어야 함 (RTL 파일 이름이 바뀌어 패키징이 깨지는 경우를 잡음)
    xml = (ip / "component.xml").read_text(encoding="utf-8")
    missing = [f for f in set(re.findall(r"<spirit:name>([\w/]+\.v)</spirit:name>", xml)) if not (ip / f).exists()]
    if missing:
        sys.exit(f"ERROR: component.xml references missing RTL: {missing}")
    return dst


def git_rev() -> str:
    try:
        return subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True,
                              text=True).stdout.strip()
    except OSError:
        return "unknown"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="mode", required=True)
    p = sub.add_parser("ooc", help="dma_ip_top 단독(out-of-context) 합성+배치배선")
    p.add_argument("--period", type=float, default=10.0, help="ap_clk 주기, ns 단위 (기본 10 = 100 MHz)")
    p = sub.add_parser("system", help="block design -> 비트스트림 + XSA")
    p.add_argument("--jobs", type=int, default=6)
    p.add_argument("--impl-strategy", default="Performance_ExplorePostRoutePhysOpt",
                   help="Vivado impl_1 전략 ('default' = Vivado 기본값). BUGS.md NOTE-001 참고")
    a = ap.parse_args()

    out = OUT / a.mode
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    t0 = time.time()
    if a.mode == "ooc":
        rc = run_vivado(VIV / "ooc.tcl", out, [str(out), f"{a.period:g}"], timeout=3600)
    else:
        repo = assemble_ip_repo(OUT / "ip_repo")
        rc = run_vivado(VIV / "build_system.tcl", out, [str(out), str(repo), str(a.jobs), a.impl_strategy],
                        timeout=4 * 3600)

    res = parse_result(out)
    res.update({"mode": a.mode, "git": git_rev(), "vivado_rc": rc,
                "elapsed_s": round(time.time() - t0), "time": time.strftime("%Y-%m-%d %H:%M:%S")})
    if a.mode == "system":
        arts = {}
        for name in ("design_1_wrapper.bit", "design_1_wrapper.xsa"):
            f = out / name
            if f.exists():
                arts[name] = {"path": str(f), "bytes": f.stat().st_size, "sha256": sha256(f)}
        res["artifacts"] = arts
    if rc != 0 or "wns" not in res or (a.mode == "system" and len(res.get("artifacts", {})) < 2):
        res["verdict"], code = "BUILD_FAIL", 2
    elif res["wns"] < 0 or res.get("whs", 0) < 0:
        res["verdict"], code = "TIMING_FAIL", 1
    else:
        res["verdict"], code = "PASS", 0
    (out / "result.json").write_text(json.dumps(res, indent=2), encoding="utf-8")

    print("=" * 72)
    print(f"[{res['verdict']}] fpga {a.mode}  WNS={res.get('wns')} ns  WHS={res.get('whs')} ns"
          f"  ({res['elapsed_s']}s, git {res['git']})")
    for k, v in res.get("utilization", {}).items():
        print(f"   {k:16s} {v['used']:>8g}  ({v['pct']}%)")
    for k, v in res.get("artifacts", {}).items():
        print(f"   {k}: {v['bytes']} bytes sha256={v['sha256'][:16]}...")
    for e in res.get("errors", [])[:5]:
        print(f"   > {e[:200]}")
    print(f"   result: {out / 'result.json'}")
    print("=" * 72)
    return code


if __name__ == "__main__":
    sys.exit(main())
