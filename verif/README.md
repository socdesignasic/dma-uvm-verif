# dma_ip verification (UVM / Vivado XSim 2022.2)

All simulation goes through `scripts/sim.py` (Jenkins and the MCP server call the same script).

```bash
python scripts/sim.py list                                   # registered testbenches
python scripts/sim.py lint --tb rtl                          # compile+elab DUT only
python scripts/sim.py run  --tb ref_adder_fixed --seed random
python scripts/sim.py run  --tb ref_adder_fixed --cov        # + code coverage (sbct)
python scripts/sim.py cov-report --tb ref_adder_fixed        # HTML -> out/<tb>/cov/
python scripts/sim.py run  --tb <tb> --wave                  # wave.wdb in run dir
```

Each run writes `out/<tb>/runs/<test>_<seed>/{run.log,result.json,junit.xml}`.
Exit code: 0 = matches expectation, 1 = test mismatch, 2 = build/tool error.

Regression: all tests of the selected TBs × N seeds, run in parallel on private snapshot copies.
JUnit/summary go to `out/regress/<name>/`.
```bash
python scripts/regress.py --suite all --seeds 2 --jobs 6      # suites: unit | top | all
python scripts/regress.py --tb top --tests dma_smoke_test dma_irq_test
```
CI (Jenkins) runs the same scripts. See `ci/README.md`.

## Testbench registry: `verif/sim_cfg.json`
| tb | purpose |
|---|---|
| `rtl` | DUT lint/elab (adder datapath, default build) |
| `ref_adder` | user UVM reference as-is; `"expect": "fail"` -> reported XFAIL (proves the checker catches bugs) |
| `ref_adder_fixed` | same TB, DUT reset polarity corrected -> PASS |
| `fifo` / `fifo_d4` | `sync_fifo` depth 64 (as in top) / depth 4 |
| `skid` | `skid_buffer` |
| `adder` / `adder8` | `axis_adder` with 2 × 32-bit lanes (module default) / 8 × 8-bit lanes (as in top) |
| `top` | `dma_ip_top`: AXI4-Lite master, AXI4 slave memory model, full RDMA → adder → WDMA path |

`known_fail` maps a test to a tracked RTL bug (`verif/BUGS.md`). It reports XFAIL,
and turns into a CI failure (XPASS) once the RTL is fixed.

## Code layout
One class per file, and the file is named after the class. Each `*_pkg.sv` only imports, declares
package-wide typedefs/constants and `` `include ``s its class files; filelists list the packages and
add a `+incdir+` per package directory.

```
verif/
  agents/vr_agent/        vr_if, vr_pkg, vr_item, vr_cfg, vr_sequencer, vr_master_driver,
                          vr_slave_driver, vr_monitor, vr_agent, vr_stream_seq
  agents/axil_agent/      axil_if, axil_pkg, axil_item, axil_sequencer, axil_driver, axil_agent,
                          axil_base_seq (write_reg / read_reg)
  agents/axi4_slv_agent/  axi4_if, axi4_slv_pkg, axi4_slv_cfg, axi4_mem, axi4_burst,
                          axi4_slv_monitor, axi4_slv_driver, axi4_slv_agent
  env/unit/               unit_env_pkg, unit_env_cfg, unit_scoreboard, unit_coverage, unit_env
  env/top/                dma_env_pkg, dma_reg_map, dma_job, dma_env_cfg, dma_scoreboard,
                          dma_coverage, dma_env
  sequences/top/          dma_seq_pkg, dma_job_seq, dma_reg_reset_seq, dma_reg_bitbash_seq
  tests/unit/             unit_test_pkg, unit_base_test, unit_<name>_test (6)
  tests/top/              dma_test_pkg, dma_base_test, dma_<name>_test (11)
  tb/                     TB top modules
```

## Unit-level UVM architecture
`vr_agent` (generic valid/ready, master/slave/passive) → `unit_env` (in/out agents,
in-order `unit_scoreboard` with per-DUT model, `unit_coverage`) → `unit_test_pkg` tests.
Structure follows `uvm_reference/` but is packaged (no global-scope includes,
no modport hierarchical refs).

## Top-level UVM architecture
No RAL: `axil_agent` programs the DUT through `axil_base_seq::write_reg()/read_reg()` with the
addresses in `env/top/dma_reg_map.sv`.
`axi4_slv_agent` is a reactive slave on m00: `axi4_slv_driver` answers from a sparse byte memory
(`axi4_mem`) with random per-channel backpressure and checks WLAST and uninitialised reads;
`axi4_slv_monitor` publishes every AR/AW and checks the burst (INCR, size, alignment, ≤16 beats, 4KB).
`dma_job_seq` runs one DMA job end to end, and `dma_scoreboard` compares every destination byte
against `src + value_to_add[7:0]`, plus guard bands, source integrity, burst windows and beat totals.
`dma_reg_reset_seq` / `dma_reg_bitbash_seq` check reset values and RW bits (all 32 bits).

## XSim on Windows: known pitfalls (handled in sim.py)
- Vivado tools are `.bat` wrappers: cmd.exe splits `UVM_TESTNAME=foo` on `=`. Args are quoted.
- Backslash paths leak into XSim-generated C code and break `--cc_type` elaboration. Paths are passed with `/`.
- `xcrg` returns exit code 127 even on success. Success is judged from its log.
- XSim `dist` with wide ranges / small weights is badly skewed. Corner bias is done procedurally (`vr_stream_seq`).
- Width-cast expressions inside `coverpoint` are mis-evaluated. Compute the value first, then sample it.
- `$` as a bin upper bound is mis-evaluated (every sample hits it). Use an explicit bound.
- `xcrg` appends to existing reports. `cov-report` clears the report dir first.
- XSim does not auto-import UVM (EDA Playground does): add `import uvm_pkg::*;` + `` `include "uvm_macros.svh" ``.
