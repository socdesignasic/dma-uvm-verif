// -----------------------------------------------------------------------------
// axi4_slv_pkg : reactive AXI4 slave agent + sparse byte memory (stands in for DDR)
// One class per file, included below.
//
//   axi4_slv_monitor : AR/AW handshakes -> axi4_burst (ar_ap / aw_ap),
//                      burst checks: INCR, 8-byte size, 8-byte aligned, <= 16 beats, no 4KB crossing
//   axi4_slv_driver  : AR -> R  (in order, random first-beat latency and inter-beat gaps)
//                      AW + W -> write engine (W may legally arrive before its AW) -> B
//                      checks: WLAST exactly on the last beat, reads of uninitialised memory
//   axi4_slv_agent   : cfg + shared axi4_mem + driver + monitor
// -----------------------------------------------------------------------------
package axi4_slv_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  typedef virtual axi4_if axi4_vif;

  `include "axi4_slv_cfg.sv"
  `include "axi4_mem.sv"
  `include "axi4_burst.sv"
  `include "axi4_slv_monitor.sv"
  `include "axi4_slv_driver.sv"
  `include "axi4_slv_agent.sv"
endpackage
