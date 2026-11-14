# Verification plan (living document)

Legend: ✅ done · 🚧 in progress · ⬜ planned

## P1: unit level (`verif/tb/unit`, `unit_env_pkg`, `unit_test_pkg`)
| Feature | Blocks | Test(s) | Check | Coverage | Status |
|---|---|---|---|---|---|
| Lossless, in-order transfer | fifo, skid, adder | all unit tests | in-order scoreboard, leftover/unexpected beats | beat count | ✅ |
| Adder per-lane add, 32-bit wrap | adder | rand, fixed_side | per-lane add model | `cp_lo/hi_carry` yes/no | ✅ |
| Adder 8-bit lanes (top configuration) | adder8 | all unit tests | same model, lane_bw=8 | | ✅ |
| ctrl_constant sampled per beat | adder | rand (side changes every beat) | model uses side captured at handshake | `cp_side` | ✅ |
| Constant value_to_add (top usage) | adder | fixed_side | same | | ✅ |
| Backpressure, FIFO full | fifo, fifo_d4 | backpressure | scoreboard | `cp_in` stalled state, `stall_release` | ✅ |
| Drain to empty, sparse input | all | trickle | scoreboard | `cp_out` idle | ✅ |
| Back-to-back full throughput | all | smoke | scoreboard | `b2b` transitions | ✅ |
| valid on first cycle after reset | skid, fifo | post_reset | scoreboard | | ❌ BUG-001 |
| valid/ready protocol (hold, no X) | all ports | all | SVA in `vr_if` (UVM_ERROR) | | ✅ |

## P2: top level `dma_ip_top` (`verif/tb/top`, `dma_env_pkg`, `dma_seq_pkg`, `dma_test_pkg`)
Env: AXI4-Lite master (`axil_agent`, register map `dma_reg_map.sv`, no RAL) → DUT → AXI4 slave agent + memory model (`axi4_slv_pkg`).
Per job: program the regs in the same order as `SW/mem_copy_test.c`, start, wait for done (poll or IRQ), then compare memory.

| Feature | Test(s) | Check | Coverage | Status |
|---|---|---|---|---|
| Register reset values (all 10 regs, all 32 bits, incl. AP_CTRL idle=1 and ISR) | dma_reg_reset_test | `dma_reg_reset_seq` | | ✅ |
| Register R/W (all RW regs except AP_CTRL, ISR): walking 1/0, unused bits read 0 | dma_reg_bitbash_test | `dma_reg_bitbash_seq` (390 checks) | | ✅ |
| dst = src + value_to_add[7:0] per byte | all job tests | byte compare of every dst byte; dst pre-poisoned with ~expected | `cp_value` 0/1/255/other | ✅ |
| value_to_add[31:8] ignored | all job tests | same | `cp_upper` | ✅ |
| No overrun/underrun, source untouched | all job tests | 64B guard bands around dst, src snapshot | | ✅ |
| Bursts INCR, 8B size and alignment, ≤16 beats | all | `axi4_slv_monitor` checks | `cp_len` 1/2-15/16 | ✅ |
| 4KB boundary split | dma_4kb_test (+ random) | AXI_4KB check, SB_RANGE | `split_at_4k` rd/wr | ✅ |
| Beat totals = bytes/8 for AR and AW | all job tests | SB_BEATS | `cp_beats` 1..8192 | ✅ |
| AXI master protocol (hold, X) | all | SVA in `axi4_if` | | ✅ |
| R/W/AR/B backpressure, R latency | rand, backpressure, large | all of the above | | ✅ |
| AWREADY backpressure | dma_aw_backpressure_test | WLAST position, completion | | ❌ BUG-002 |
| Completion by polling AP_CTRL.done (COR) | most | done bit, interrupt stays low with GIE=0 | `cp_mode` | ✅ |
| Completion by interrupt (GIE/IER/ISR) | dma_irq_test, rand | ISR[0] set, IRQ drops after ISR read | `cp_mode` | ✅ |
| Exact size edges (1 beat, 16 = one full burst, 512 = one 4KB page) × poll and IRQ completion | dma_size_edge_test | byte compare, SB_BEATS, IRQ checks | `x_size_mode` one/max_burst/page × both modes | ✅ |
| Back-to-back jobs, return to idle | all multi-job tests | AP_CTRL.idle after each job | | ✅ |
| transfer_byte = 0 / not a multiple of 8 | (not tested) | SW forbids it; RTL would hang on 0 | | ⬜ out of spec |
| auto_restart | (not tested) | | | ⬜ |
