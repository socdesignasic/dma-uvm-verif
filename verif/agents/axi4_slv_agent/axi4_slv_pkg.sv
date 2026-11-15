// -----------------------------------------------------------------------------
// axi4_slv_pkg : 반응형 AXI4 slave agent + 희소 바이트 메모리 (DDR 대신 사용)
// 파일 하나에 클래스 하나. 아래에서 include합니다.
//
//   axi4_slv_monitor : AR/AW handshake -> axi4_burst (ar_ap / aw_ap),
//                      burst 검사: INCR, 8바이트 size, 8바이트 정렬, 16 beat 이하, 4KB 경계 넘지 않음
//   axi4_slv_driver  : AR -> R  (순서대로, 첫 beat 지연과 beat 사이 간격은 랜덤)
//                      AW + W -> write engine (W가 AW보다 먼저 와도 규격상 허용) -> B
//                      검사: WLAST가 정확히 마지막 beat에 오는지, 초기화 안 된 메모리를 읽는지
//   axi4_slv_agent   : 설정 + 공유 axi4_mem + driver + monitor
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
