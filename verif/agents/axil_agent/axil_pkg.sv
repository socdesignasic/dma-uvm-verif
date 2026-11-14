// -----------------------------------------------------------------------------
// axil_pkg : AXI4-Lite master agent (one class per file, included below)
//   Register access goes through axil_base_seq::write_reg()/read_reg().
// -----------------------------------------------------------------------------
package axil_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  typedef virtual axil_if axil_vif;

  `include "axil_item.sv"
  `include "axil_sequencer.sv"
  `include "axil_driver.sv"
  `include "axil_agent.sv"
  `include "axil_base_seq.sv"
endpackage
