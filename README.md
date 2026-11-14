# dma-uvm-verif

UVM verification environment, CI/CD and agent tooling for a simple AXI DMA IP
(`dma_ip_top`: RDMA → FIFO → adder → FIFO → WDMA, AXI4-Lite control, AXI4 master)
on Vivado 2022.2 XSim, targeting a Zybo Z7-20 (xc7z020clg400-1).

> **The DUT RTL is not included.** This repository holds the
> verification code only. Before running, add (all ignored by git here):
> - `HW/`: the DUT RTL. The testbenches expect the files and module names listed in
>   `verif/filelist/rtl.f` and the unit filelists (top module `dma_ip_top`)
> - `uvm_reference/`: the reference UVM example (only the `ref_adder*` testbenches use it)
> - `ci/vivado/ip/dma_ip_top/`: IP packaging metadata (`component.xml`, `xgui/`),
>   needed only by `scripts/fpga.py system` (bitstream build)
> - `SW/`: the board test program (not used by simulation or CI)

## What is here

| Path | What |
|---|---|
| `verif/` | UVM testbenches: agents, envs, sequences, tests, TB tops, test registry (`sim_cfg.json`), vplan, bug tracker |
| `scripts/` | `sim.py` (lint/run/coverage), `regress.py` (parallel regression), `fpga.py` (OOC timing, bitstream + XSA) |
| `Jenkinsfile`, `ci/` | Local Jenkins (Configuration as Code), Vivado block design and IP packaging scripts |
| `mcp/` | MCP server that exposes the simulation flow to agents |
| `.claude/`, `CLAUDE.md` | Agent rules, subagents, `/verify-loop` skill, hook that keeps `HW/` read-only |
| `docs/` | Results report, repository layout, flow, UVM code structure |

## Quick start (with the RTL in `HW/`)

```bash
python scripts/sim.py list
python scripts/sim.py run --tb top --test dma_smoke_test --seed 1
python scripts/regress.py --suite all --seeds 2 --jobs 6
python scripts/sim.py cov-report --tb top
```

See `docs/ARCHITECTURE.md`, `docs/FLOW.md` and `docs/UVM_STRUCTURE.md` for details,
and `verif/BUGS.md` for the RTL issues the environment found.
