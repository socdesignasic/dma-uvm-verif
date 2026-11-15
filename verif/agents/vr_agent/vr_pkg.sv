// -----------------------------------------------------------------------------
// vr_pkg : 범용 valid/ready UVM agent (파일 하나에 클래스 하나, 아래에서 include)
//   VR_MASTER  : sequencer + master driver가 valid/data/side 구동
//   VR_SLAVE   : slave driver가 랜덤 backpressure로 ready 구동 (sequencer 없음)
//   VR_PASSIVE : monitor만
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
