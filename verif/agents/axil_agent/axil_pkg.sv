// -----------------------------------------------------------------------------
// axil_pkg : AXI4-Lite master agent (파일 하나에 클래스 하나, 아래에서 include)
//   레지스터 접근은 axil_base_seq::write_reg()/read_reg()로 합니다.
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
