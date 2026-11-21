// -----------------------------------------------------------------------------
// axil_pkg : AXI4-Lite master agent + monitor + uvm_reg adapter (파일 하나에 클래스 하나, 아래에서 include)
//   top TB는 RAL로 레지스터에 접근합니다 (regmodel frontdoor -> axil_reg_adapter -> 이 agent의 sequencer).
//   axil_reg_base_seq(write_reg()/read_reg())는 RAL 없이 직접 접근할 때 쓰는 기본 sequence로 남습니다.
// -----------------------------------------------------------------------------
package axil_pkg;                                   // 패키지 시작
  import uvm_pkg::*;                                // UVM 라이브러리 import
  `include "uvm_macros.svh"                         // UVM 매크로 포함

  typedef virtual axil_if axil_vif;                 // virtual interface 타입 별칭

  `include "axil_cfg.svh"                            // driver 타이밍 노브
  `include "axil_item.svh"                           // 트랜잭션 item
  `include "axil_sequencer.svh"                      // sequencer
  `include "axil_driver.svh"                         // driver
  `include "axil_monitor.svh"                        // monitor
  `include "axil_agent.svh"                          // agent
  `include "axil_reg_base_seq.svh"                       // RAL 없이 직접 레지스터에 접근하는 기본 sequence
  `include "axil_reg_adapter.svh"                    // uvm_reg adapter
endpackage                                          // 패키지 끝
