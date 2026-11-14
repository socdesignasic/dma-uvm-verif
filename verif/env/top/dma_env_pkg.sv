// -----------------------------------------------------------------------------
// dma_env_pkg : top-level env for dma_ip_top (one class per file, included below)
//
//   axil_agt (AXI4-Lite master) ---> control regs ---> DUT ---> m00 AXI4 ---> mem_agt (slave + memory)
//                                                                     |
//   dma_scoreboard <-- AR/AW bursts ----------------------------------'   + memory compare per job
//   dma_coverage   <-- jobs + bursts
//
// A "job" is one DMA run (see verif/sequences/top/dma_job_seq.sv): program regs, start,
// wait done (poll or interrupt), then check  dst[i] == src[i] + value_to_add[7:0]
// for every byte (dma_ip_top instantiates the adder with C_ADDER_BIT_WIDTH = 8).
// -----------------------------------------------------------------------------
package dma_env_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axil_pkg::*;
  import axi4_slv_pkg::*;

  localparam int unsigned GUARD   = 64;     // bytes checked around dst for overrun
  localparam int unsigned BEAT    = 8;      // bytes per AXI beat
  localparam int unsigned LANE_BW = 8;      // adder lane width in dma_ip_top

  typedef enum {DONE_POLL, DONE_IRQ} done_mode_e;

  `include "dma_reg_map.sv"
  `include "dma_job.sv"
  `include "dma_env_cfg.sv"
  `include "dma_scoreboard.sv"
  `include "dma_coverage.sv"
  `include "dma_env.sv"
endpackage
