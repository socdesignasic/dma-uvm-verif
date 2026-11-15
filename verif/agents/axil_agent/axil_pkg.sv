// -----------------------------------------------------------------------------
// axil_pkg : AXI4-Lite master agent (파일 하나에 클래스 하나, 아래에서 include)
//   레지스터 접근은 axil_base_seq::write_reg()/read_reg()로 합니다.
// -----------------------------------------------------------------------------
package axil_pkg;                                   // 패키지 시작
  import uvm_pkg::*;                                // UVM 라이브러리 import
  `include "uvm_macros.svh"                         // UVM 매크로 포함

  typedef virtual axil_if axil_vif;                 // virtual interface 타입 별칭

  `include "axil_item.sv"                           // 트랜잭션 item
  `include "axil_sequencer.sv"                      // sequencer
  `include "axil_driver.sv"                         // driver
  `include "axil_agent.sv"                          // agent
  `include "axil_base_seq.sv"                       // 레지스터 접근 기본 sequence
endpackage                                          // 패키지 끝
