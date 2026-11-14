# RTL bug tracker (found by verification)

RTL under `HW/` is not modified by the verification flow. Each bug is reproduced
by a test that is registered as `known_fail` in `verif/sim_cfg.json`, so CI stays
green (reported as XFAIL / skipped). Once the RTL is fixed, the test turns XPASS
and CI fails, which is the reminder to remove the `known_fail` entry.

## BUG-001: skid buffer duplicates a beat accepted while `s_ready=0` after reset
- **Block:** `HW/peri_ip/skid_buffer.v` (also inside `sync_fifo`, both IN and OUT stages)
- **Status:** won't fix (RTL owner decision, 2026-11-14). Stays a permanent `known_fail`.
- **Reproducer:** `python scripts/sim.py run --tb skid --test unit_post_reset_test --seed 1`
  (also `fifo`, `fifo_d4`; fails for every seed)
- **Symptom:** the first beat comes out twice and every later beat is shifted by one.
  ```
  105ns  s_valid=1, s_ready=0   (no handshake per AXI-Stream rules)
  115ns  out: 0x..6f004183        (beat captured at 105ns)
         in : 0x..6f004183 accepted (s_ready=1 now; the source re-sends)
  125ns  out: 0x..6f004183        <- duplicate
  ```
- **Root cause:** `s_ready_reg` resets to 0, but in state `PIPE` the buffer loads
  `m_valid_reg <= s_valid` whenever downstream is ready, **without checking
  `s_ready_reg`**. On the first cycle out of reset `s_ready=0`, so a source that
  asserts `valid` immediately (legal) is captured without a handshake and then
  re-sent.
- **Suggested fix (needs RTL owner approval):** qualify the captures with the
  handshake, e.g. `m_valid_reg <= s_valid & s_ready_reg;` and
  `m_valid_temp_reg <= s_valid & s_ready_reg;`.
- **Impact on dma_ip_top:** low in practice. The FIFOs are fed by RDMA, which
  starts only after `ap_start`, long after reset, so the window is not hit
  on the board today. Any upstream that drives valid right out of reset would hit it.

## BUG-002: WDMA sends W beats before AW is accepted, miscounts them, hangs
- **Block:** `HW/dma_ip/WDMA/wdma.v`
- **Status:** open (RTL is not modified by verification; waiting on the RTL owner's decision)
- **Reproducer:** `python scripts/sim.py run --tb top --test dma_aw_backpressure_test --seed 1`
  (any seed; any slave that holds AWREADY low while write data is ready)
- **Symptom:** `WLAST` comes late (beat 19 instead of 16), every later burst is shifted,
  the B-response count never reaches the total, and **`ap_done` never asserts (hang)**.
  Data bytes still land at the right addresses because the memory model writes in beat order.
  ```
  715/745/755ns  W beats #1-3 accepted   (no AW accepted yet, W FSM in IDLE)
  765ns          AW #0 accepted (16 beats)
  1135ns         beat #16, WLAST=0  <- slave expects WLAST here
  1235ns         beat #19, WLAST=1
  ```
- **Root cause:** `m_axi_gmem_WVALID = s_valid` (FIFO not empty) and `s_ready = WREADY`
  are not gated by the W state machine. `r_burst_cnt_w` is held at 0 while
  `c_state_w == S_IDLE` (no AW in the AW->W FIFO yet), so beats accepted then are
  never counted. W-before-AW is legal AXI for the bus, but the WDMA's own
  WLAST/B bookkeeping assumes it never happens.
- **Suggested fix (needs RTL owner approval):**
  `assign m_axi_gmem_WVALID = s_valid & w_s_run_w;` and
  `assign s_ready = m_axi_gmem_WREADY & w_s_run_w;`
- **Impact on the board:** real hang risk. Zynq HP ports or an AXI interconnect / SmartConnect
  can delay AWREADY. The tutorial setup has worked so far because AWREADY usually comes
  back quickly.
- **Verification impact:** every other top test keeps AWREADY=1 (W/AR/R/B backpressure stays
  random), so the rest of the design is still checked. Only `dma_aw_backpressure_test` exercises
  AWREADY delay, and it is registered as `known_fail`.

---
# Design notes (not functional bugs)

## NOTE-001: WDMA burst-address loop has almost no timing margin at 100 MHz
- **Found by:** `python scripts/fpga.py ooc` (P6), xc7z020clg400-1, ap_clk 10 ns, out-of-context P&R
- **Result:** WNS = **+0.014 ns** (met, but with essentially no margin). WHS = +0.125 ns. 1931 LUT / 5315 FF.
- **Critical path:** `u_wdma/r_hs_data_cnt_reg[1] -> r_hs_data_cnt_reg[21]`, 20 logic levels
  (12 CARRY4). `r_hs_data_cnt` feeds `remain_hs`, the 16-beat clamp, the 4KB-boundary math
  (`last_addr_in_burst`, `boudary_burst_len_4k`), `burst_len_aw`, and back into `r_hs_data_cnt`, all in one cycle.
  `rdma` has the same structure.
- **Full system @100 MHz (PS7 + interconnect + ILA):** the same loop **fails** with the default
  implementation strategy, in both the hand-made project and the CD build:

  | Build | Impl strategy | WNS | Failing endpoints | Worst path |
  |---|---|---|---|---|
  | hand-made `mem_copy_vivado` | default | -0.201 ns | 6 | RDMA `r_hs_data_cnt` |
  | CD `71cdca3` | default | -0.347 ns | 12 | RDMA `r_hs_data_cnt` (22 levels) |
  | CD `71cdca3` | `Performance_ExplorePostRoutePhysOpt` | **+0.003 ns** | 0 | WDMA `r_hs_data_cnt` (17 levels) |

  `scripts/fpga.py system` now uses the explore strategy by default, with phys_opt enabled before and
  after routing. Timing is met, but the +0.003 ns margin is so thin that another placement (or any
  RTL/BD change) may fail again. CI fails the FPGA stage on WNS < 0.
- **Possible improvement (RTL owner):** register `burst_len_aw` / the boundary length one cycle
  earlier. The AW FSM already spends a cycle in `S_PRE`, so the result can be precomputed there.
