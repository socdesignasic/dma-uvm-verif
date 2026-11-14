# dma-uvm: agent working rules

UVM verification of `dma_ip_top` (Zybo Z7-20) on **Vivado 2022.2 XSim**, CI on a local
Jenkins (http://localhost:8090), repo `socdesignasic/dma-uvm` (private).

## Hard rules
1. **RTL under `HW/` is read-only.** A `PreToolUse` hook blocks edits. When a test exposes an RTL bug,
   do not fix it. Add it to `verif/BUGS.md` (symptom, root cause, reproducer, suggested fix) and register
   the reproducer as `known_fail` in `verif/sim_cfg.json`. Then stop and report to the user (human gate).
2. **Simulate only through `scripts/sim.py` / `scripts/regress.py`**, or the `vivado` MCP tools that wrap
   them. Never call xvlog/xelab/xsim directly. CI runs the same scripts, so local = CI.
3. **Commit / push only when the user explicitly asks.**
4. A test result counts only if it was run. Quote the verdict and the `rerun` command. Never claim
   a PASS you did not observe.
5. Do not lower a check, widen a tolerance or delete an assertion to make a test pass. A failing
   check is either a TB bug (fix the TB) or an RTL bug (rule 1).

## Layout
| Path | What |
|---|---|
| `HW/` | DUT RTL (read-only) |
| `verif/agents/` | `vr_agent` (valid/ready), `axil_agent` (AXI4-Lite master, `write_reg`/`read_reg`), `axi4_slv_agent` (driver + monitor + memory model) |
| `verif/env/{unit,top}/`, `verif/sequences/top/`, `verif/tests/{unit,top}/`, `verif/tb/` | envs (scoreboard, coverage, register map), sequences, tests, TB tops |
| `verif/sim_cfg.json` | TB registry: filelists, tests, `known_fail` |
| `verif/vplan/vplan.md` | feature ↔ test ↔ coverage map (keep it updated) |
| `verif/BUGS.md` | RTL bugs found (BUG-001 won't fix, BUG-002 open) |
| `scripts/` | `sim.py`, `regress.py` |
| `ci/`, `Jenkinsfile` | Jenkins (JCasC) |
| `mcp/` | `vivado` MCP server; Jenkins/GitHub MCP setup |
| `.claude/agents/`, `.claude/skills/` | subagents and the orchestration loop (`/verify-loop`) |

## Commands
```bash
python scripts/sim.py list
python scripts/sim.py lint --tb top
python scripts/sim.py run --tb top --test dma_smoke_test --seed 1
python scripts/regress.py --suite all --seeds 2 --jobs 6
python scripts/sim.py cov-report --tb top     # out/top/cov/func/xcrg_func_cov_report.txt
```

## XSim 2022.2 pitfalls (already handled, don't reintroduce)
- `dist` over wide ranges is badly skewed. Bias corner values procedurally.
- Width casts inside `coverpoint` expressions are mis-evaluated. Compute first, then sample.
- `small`, `large`, `medium`, `weak*`, `strong*` are keywords. Don't use them as bin names.
- A function-call result cannot be bit-selected (`f()[3:0]`). Use a temp variable.
- `$` as a bin upper bound (`[513:$]`) is mis-evaluated: every sample hits the bin. Use an explicit bound.
- `xcrg` appends to existing reports. `sim.py cov-report` clears `out/<tb>/cov` first.

## UVM code layout
- **One class per file, file name = class name** (`dma_scoreboard` → `dma_scoreboard.sv`).
- A `*_pkg.sv` holds only imports, package-wide typedefs/constants and `` `include `` lines.
  Class files are not listed in filelists; the filelist has a `+incdir+` for each package directory.
- No RAL. Registers are accessed with `axil_base_seq::write_reg()/read_reg()` and the constants in
  `verif/env/top/dma_reg_map.sv`.
- Stimulus lives in sequences (`verif/sequences/top/`, `vr_stream_seq`), not in the env.

## Adding a test
Create `verif/tests/<unit|top>/<test_name>.sv` (one class), add an `` `include `` line to that
directory's `*_test_pkg.sv`, add it to the TB's `tests` list in `verif/sim_cfg.json` (that is what CI
and `regress.py` run), add a row to `verif/vplan/vplan.md`, then lint → run 3+ seeds → regress the
affected suite.
