// -----------------------------------------------------------------------------
// vr_pkg : generic valid/ready UVM agent (one class per file, included below)
//   VR_MASTER  : sequencer + master driver drive valid/data/side
//   VR_SLAVE   : slave driver drives ready with random backpressure (no sequencer)
//   VR_PASSIVE : monitor only
// -----------------------------------------------------------------------------
package vr_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  typedef virtual vr_if #(64) vr_vif;
  typedef enum {VR_MASTER, VR_SLAVE, VR_PASSIVE} vr_mode_e;

  `include "vr_item.sv"
  `include "vr_cfg.sv"
  `include "vr_sequencer.sv"
  `include "vr_master_driver.sv"
  `include "vr_slave_driver.sv"
  `include "vr_monitor.sv"
  `include "vr_agent.sv"
  `include "vr_stream_seq.sv"
endpackage
