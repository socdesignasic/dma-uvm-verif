#!/usr/bin/env python3
"""
fpga.py - single entry point for the FPGA implementation flow (P6, "CD").

  python scripts/fpga.py ooc                 # dma_ip_top alone: synth+P&R @100 MHz, timing/util
  python scripts/fpga.py ooc --period 7.5    # margin check at 133 MHz
  python scripts/fpga.py system              # PS7 + DMA block design -> bitstream + XSA
  python scripts/fpga.py system --impl-strategy default   # Vivado default impl strategy

Outputs (under out/fpga/<mode>/):
  result.json        verdict, WNS/WHS, utilization, artifact paths, sha256 of bit/xsa
  timing_summary.rpt, utilization.rpt, vivado.log
  design_1_wrapper.bit / .xsa      (system only; the XSA is what Vitis consumes)

Exit code: 0 = built and timing met, 1 = timing violated, 2 = tool/build error.
RTL comes from HW/ only. The IP repo is assembled here from HW/ + ci/vivado/ip/ metadata,
so the bitstream is always built from exactly the RTL that was verified.
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
    # Windows .bat wrapper: same quoting/forward-slash rules as sim.py
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
    """IP repo = packaging metadata (component.xml, xgui) + the RTL tree from HW/."""
    ip = dst / "dma_ip_top"
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(VIV / "ip" / "dma_ip_top", ip)
    for sub in ("dma_ip", "peri_ip"):
        shutil.copytree(ROOT / "HW" / sub, ip / sub)
    # every file the IP declares must exist (catches RTL renames that break packaging)
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
    p = sub.add_parser("ooc", help="out-of-context synth+P&R of dma_ip_top")
    p.add_argument("--period", type=float, default=10.0, help="ap_clk period in ns (default 10 = 100 MHz)")
    p = sub.add_parser("system", help="block design -> bitstream + XSA")
    p.add_argument("--jobs", type=int, default=6)
    p.add_argument("--impl-strategy", default="Performance_ExplorePostRoutePhysOpt",
                   help="Vivado impl_1 strategy ('default' = Vivado default). See BUGS.md NOTE-001")
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
